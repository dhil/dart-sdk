// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:kernel/ast.dart' as ir;

import '../closure.dart';
import '../common.dart';
import '../common/names.dart';
import '../constants/constant_system.dart';
import '../constants/values.dart';
import '../elements/entities.dart';
import '../elements/jumps.dart';
import '../elements/types.dart';
import '../js_backend/backend.dart';
import '../js_model/element_map.dart';
import '../js_model/locals.dart' show JumpVisitor;
import '../js_model/js_world.dart';
import '../native/behavior.dart';
import '../options.dart';
import '../types/abstract_value_domain.dart';
import '../types/types.dart';
import '../universe/selector.dart';
import '../universe/side_effects.dart';
import 'inferrer_engine.dart';
import 'locals_handler.dart';
import 'type_graph_nodes.dart';
import 'type_system.dart';

/// Whether the static type of property gets and method invocations is used
/// to narrow the inferred type in strong mode.
bool useStaticResultTypes = false;

/// [KernelTypeGraphBuilder] constructs a type-inference graph for a particular
/// element.
///
/// Calling [run] will start the work of visiting the body of the code to
/// construct a set of inference-nodes that abstractly represent what the code
/// is doing.
class KernelTypeGraphBuilder extends ir.Visitor<TypeInformation> {
  final CompilerOptions _options;
  final JsClosedWorld _closedWorld;
  final InferrerEngine _inferrer;
  final TypeSystem _types;
  final MemberEntity _analyzedMember;
  final ir.Node _analyzedNode;
  final KernelToLocalsMap _localsMap;
  final GlobalTypeInferenceElementData _memberData;
  final bool _inGenerativeConstructor;

  LocalsHandler _locals;
  final SideEffectsBuilder _sideEffectsBuilder;
  final Map<JumpTarget, List<LocalsHandler>> _breaksFor =
      <JumpTarget, List<LocalsHandler>>{};
  final Map<JumpTarget, List<LocalsHandler>> _continuesFor =
      <JumpTarget, List<LocalsHandler>>{};
  TypeInformation _returnType;
  final Set<Local> _capturedVariables = new Set<Local>();

  /// Whether we currently collect [IsCheck]s.
  bool _accumulateIsChecks = false;
  bool _conditionIsSimple = false;

  /// The [IsCheck]s that show us what types locals currently _are_.
  List<IsCheck> _positiveIsChecks;

  /// The [IsCheck]s that show us what types locals currently are _not_.
  List<IsCheck> _negativeIsChecks;

  KernelTypeGraphBuilder(this._options, this._closedWorld, this._inferrer,
      this._analyzedMember, this._analyzedNode, this._localsMap,
      [this._locals])
      : this._types = _inferrer.types,
        this._memberData = _inferrer.dataOfMember(_analyzedMember),
        // TODO(johnniwinther): Should side effects also be tracked for field
        // initializers?
        this._sideEffectsBuilder = _analyzedMember is FunctionEntity
            ? _inferrer.inferredDataBuilder
                .getSideEffectsBuilder(_analyzedMember)
            : new SideEffectsBuilder.free(_analyzedMember),
        this._inGenerativeConstructor = _analyzedNode is ir.Constructor {
    if (_locals != null) return;

    FieldInitializationScope fieldScope =
        _inGenerativeConstructor ? new FieldInitializationScope() : null;
    _locals = new LocalsHandler(_analyzedNode, fieldScope);
  }

  JsToElementMap get _elementMap => _closedWorld.elementMap;

  ClosureData get _closureDataLookup => _closedWorld.closureDataLookup;

  int _loopLevel = 0;

  bool get inLoop => _loopLevel > 0;

  bool get _isThisExposed {
    return _inGenerativeConstructor ? _locals.fieldScope.isThisExposed : true;
  }

  void _markThisAsExposed() {
    if (_inGenerativeConstructor) {
      _locals.fieldScope.isThisExposed = true;
    }
  }

  /// Returns `true` if [member] is defined in a subclass of the current this
  /// type.
  bool _isInClassOrSubclass(MemberEntity member) {
    ClassEntity cls = _elementMap.getMemberThisType(_analyzedMember)?.element;
    if (cls == null) return false;
    return _closedWorld.classHierarchy.isSubclassOf(member.enclosingClass, cls);
  }

  /// Checks whether the access or update of [selector] on [mask] potentially
  /// exposes `this`.
  ///
  /// If all matching members are instance fields on the current `this`
  /// class or subclasses, `this` is not considered to be exposed.
  ///
  /// If an instance field matched with a [selector] that is _not_ a setter, the
  /// field is considered to have been read before initialization and the field
  /// is assumed to be potentially `null`.
  void _checkIfExposesThis(Selector selector, AbstractValue mask) {
    if (_isThisExposed) {
      // We already consider `this` to have been exposed.
      return;
    }
    if (_inferrer.closedWorld.includesClosureCall(selector, mask)) {
      // TODO(ngeoffray): We could do better here if we knew what we
      // are calling does not expose this.
      _markThisAsExposed();
    } else {
      _inferrer.forEachElementMatching(selector, mask, (MemberEntity element) {
        if (element != null && element.isField) {
          FieldEntity field = element;
          if (!selector.isSetter &&
              _isInClassOrSubclass(field) &&
              field.isAssignable &&
              _locals.fieldScope.readField(field) == null &&
              getFieldInitializer(_elementMap, field) == null) {
            // If the field is being used before this constructor
            // actually had a chance to initialize it, say it can be
            // null.
            _inferrer.recordTypeOfField(field, _types.nullType);
          }
          // Accessing a field does not expose `this`.
          return true;
        }
        // TODO(ngeoffray): We could do better here if we knew what we
        // are calling does not expose this.
        _markThisAsExposed();
        return false;
      });
    }
  }

  TypeInformation run() {
    if (_analyzedMember.isField) {
      if (_analyzedNode == null || _analyzedNode is ir.NullLiteral) {
        // Eagerly bailout, because computing the closure data only
        // works for functions and field assignments.
        return _types.nullType;
      }
    }

    // Update the locals that are boxed in [locals]. These locals will
    // be handled specially, in that we are computing their LUB at
    // each update, and reading them yields the type that was found in a
    // previous analysis of [outermostElement].
    ScopeInfo scopeInfo = _closureDataLookup.getScopeInfo(_analyzedMember);
    scopeInfo.forEachBoxedVariable((variable, field) {
      _locals.setCapturedAndBoxed(variable, field);
    });

    return visit(_analyzedNode);
  }

  bool isIncompatibleInvoke(FunctionEntity function, ArgumentsTypes arguments) {
    ParameterStructure parameterStructure = function.parameterStructure;

    return arguments.positional.length <
            parameterStructure.requiredParameters ||
        arguments.positional.length > parameterStructure.positionalParameters ||
        arguments.named.keys
            .any((name) => !parameterStructure.namedParameters.contains(name));
  }

  void recordReturnType(TypeInformation type) {
    FunctionEntity analyzedMethod = _analyzedMember;
    _returnType =
        _inferrer.addReturnTypeForMethod(analyzedMethod, _returnType, type);
  }

  void initializationIsIndefinite() {
    if (_inGenerativeConstructor) {
      _locals.fieldScope.isIndefinite = true;
    }
  }

  TypeInformation _thisType;
  TypeInformation get thisType {
    if (_thisType != null) return _thisType;
    ClassEntity cls = _elementMap.getMemberThisType(_analyzedMember)?.element;
    if (_closedWorld.isUsedAsMixin(cls)) {
      return _thisType = _types.nonNullSubtype(cls);
    } else {
      return _thisType = _types.nonNullSubclass(cls);
    }
  }

  TypeInformation visit(ir.Node node, {bool conditionContext: false}) {
    var oldAccumulateIsChecks = _accumulateIsChecks;
    _accumulateIsChecks = conditionContext;
    var result = node?.accept(this);
    _accumulateIsChecks = oldAccumulateIsChecks;
    return result;
  }

  void visitList(List<ir.Node> nodes) {
    if (nodes == null) return;
    nodes.forEach(visit);
  }

  void handleParameter(ir.VariableDeclaration node, {bool isOptional}) {
    Local local = _localsMap.getLocalVariable(node);
    DartType type = _localsMap.getLocalType(_elementMap, local);
    _locals.update(
        _inferrer, local, _inferrer.typeOfParameter(local), node, type);
    if (isOptional) {
      TypeInformation type;
      if (node.initializer != null) {
        type = visit(node.initializer);
      } else {
        type = _types.nullType;
      }
      _inferrer.setDefaultTypeOfParameter(local, type,
          isInstanceMember: _analyzedMember.isInstanceMember);
    }
  }

  @override
  TypeInformation visitConstructor(ir.Constructor node) {
    handleParameters(node.function);
    node.initializers.forEach(visit);
    visit(node.function.body);

    ClassEntity cls = _analyzedMember.enclosingClass;
    if (!(node.initializers.isNotEmpty &&
        node.initializers.first is ir.RedirectingInitializer)) {
      // Iterate over all instance fields, and give a null type to
      // fields that we haven't initialized for sure.
      _elementMap.elementEnvironment.forEachLocalClassMember(cls,
          (MemberEntity member) {
        if (member.isField && member.isInstanceMember && member.isAssignable) {
          TypeInformation type = _locals.fieldScope.readField(member);
          MemberDefinition definition = _elementMap.getMemberDefinition(member);
          assert(definition.kind == MemberKind.regular);
          ir.Field node = definition.node;
          if (type == null &&
              (node.initializer == null ||
                  node.initializer is ir.NullLiteral)) {
            _inferrer.recordTypeOfField(member, _types.nullType);
          }
        }
      });
    }
    _inferrer.recordExposesThis(_analyzedMember, _isThisExposed);

    if (cls.isAbstract) {
      if (_closedWorld.classHierarchy.isInstantiated(cls)) {
        _returnType = _types.nonNullSubclass(cls);
      } else {
        // TODO(johnniwinther): Avoid analyzing [_analyzedMember] in this
        // case; it's never called.
        _returnType = _types.nonNullEmpty();
      }
    } else {
      _returnType = _types.nonNullExact(cls);
    }
    assert(_breaksFor.isEmpty);
    assert(_continuesFor.isEmpty);
    return _returnType;
  }

  @override
  visitFieldInitializer(ir.FieldInitializer node) {
    TypeInformation rhsType = visit(node.value);
    FieldEntity field = _elementMap.getField(node.field);
    _locals.updateField(field, rhsType);
    _inferrer.recordTypeOfField(field, rhsType);
    return null;
  }

  @override
  visitSuperInitializer(ir.SuperInitializer node) {
    ConstructorEntity constructor = _elementMap.getConstructor(node.target);
    ArgumentsTypes arguments = analyzeArguments(node.arguments);
    Selector selector = new Selector(SelectorKind.CALL, constructor.memberName,
        _elementMap.getCallStructure(node.arguments));
    AbstractValue mask = _memberData.typeOfSend(node);
    handleConstructorInvoke(
        node, node.arguments, selector, mask, constructor, arguments);

    _inferrer.analyze(constructor);
    if (_inferrer.checkIfExposesThis(constructor)) {
      _markThisAsExposed();
    }
    return null;
  }

  @override
  visitRedirectingInitializer(ir.RedirectingInitializer node) {
    ConstructorEntity constructor = _elementMap.getConstructor(node.target);
    ArgumentsTypes arguments = analyzeArguments(node.arguments);
    Selector selector = new Selector(SelectorKind.CALL, constructor.memberName,
        _elementMap.getCallStructure(node.arguments));
    AbstractValue mask = _memberData.typeOfSend(node);
    handleConstructorInvoke(
        node, node.arguments, selector, mask, constructor, arguments);

    _inferrer.analyze(constructor);
    if (_inferrer.checkIfExposesThis(constructor)) {
      _markThisAsExposed();
    }
    return null;
  }

  @override
  visitLocalInitializer(ir.LocalInitializer node) {
    visit(node.variable);
    return null;
  }

  void handleParameters(ir.FunctionNode node) {
    int position = 0;
    for (ir.VariableDeclaration parameter in node.positionalParameters) {
      handleParameter(parameter,
          isOptional: position >= node.requiredParameterCount);
      position++;
    }
    for (ir.VariableDeclaration parameter in node.namedParameters) {
      handleParameter(parameter, isOptional: true);
    }
  }

  @override
  TypeInformation visitFunctionNode(ir.FunctionNode node) {
    handleParameters(node);

    if (_closedWorld.nativeData.isNativeMember(_analyzedMember)) {
      // Native methods do not have a body, and we currently just say
      // they return dynamic.
      return _types.dynamicType;
    }

    visit(node.body);
    switch (node.asyncMarker) {
      case ir.AsyncMarker.Sync:
        if (_returnType == null) {
          // No return in the body.
          _returnType = _locals.seenReturnOrThrow
              ? _types.nonNullEmpty() // Body always throws.
              : _types.nullType;
        } else if (!_locals.seenReturnOrThrow) {
          // We haven'TypeInformation seen returns on all branches. So the
          // method may also return null.
          recordReturnType(_types.nullType);
        }
        break;

      case ir.AsyncMarker.SyncStar:
        // TODO(asgerf): Maybe make a ContainerTypeMask for these? The type
        //               contained is the method body's return type.
        recordReturnType(_types.syncStarIterableType);
        break;

      case ir.AsyncMarker.Async:
        recordReturnType(_types.asyncFutureType);
        break;

      case ir.AsyncMarker.AsyncStar:
        recordReturnType(_types.asyncStarStreamType);
        break;
      case ir.AsyncMarker.SyncYielding:
        failedAt(
            _analyzedMember, "Unexpected async marker: ${node.asyncMarker}");
        break;
    }
    assert(_breaksFor.isEmpty);
    assert(_continuesFor.isEmpty);
    return _returnType;
  }

  @override
  TypeInformation visitInstantiation(ir.Instantiation node) {
    // TODO(sra): Add a TypeInformation for Instantiations.  Instantiated
    // generic methods will need to be traced separately, and have the
    // information gathered in tracing reflected back to the generic method. For
    // now, pass along the uninstantiated method.
    return visit(node.expression);
  }

  @override
  TypeInformation defaultExpression(ir.Expression node) {
    throw new UnimplementedError(
        'Unhandled expression: ${node} (${node.runtimeType})');
  }

  @override
  defaultStatement(ir.Statement node) {
    throw new UnimplementedError(
        'Unhandled statement: ${node} (${node.runtimeType})');
  }

  @override
  TypeInformation visitNullLiteral(ir.NullLiteral literal) {
    return _types.nullType;
  }

  @override
  visitBlock(ir.Block block) {
    for (ir.Statement statement in block.statements) {
      visit(statement);
      if (_locals.aborts) break;
    }
    return null;
  }

  @override
  visitExpressionStatement(ir.ExpressionStatement node) {
    visit(node.expression);
    return null;
  }

  @override
  visitEmptyStatement(ir.EmptyStatement node) {
    // Nothing to do.
    return null;
  }

  @override
  visitAssertStatement(ir.AssertStatement node) {
    // Avoid pollution from assert statement unless enabled.
    if (!_options.enableUserAssertions) {
      return null;
    }
    // TODO(johnniwinther): Should assert be used with --trust-type-annotations?
    // TODO(johnniwinther): Track reachable for assertions known to fail.
    List<IsCheck> positiveTests = <IsCheck>[];
    List<IsCheck> negativeTests = <IsCheck>[];
    bool simpleCondition =
        handleCondition(node.condition, positiveTests, negativeTests);
    LocalsHandler saved = _locals;
    _locals = new LocalsHandler.from(_locals, node);
    _updateIsChecks(positiveTests, negativeTests);

    LocalsHandler thenLocals = _locals;
    _locals = new LocalsHandler.from(saved, node);
    if (simpleCondition) _updateIsChecks(negativeTests, positiveTests);
    visit(node.message);
    _locals.seenReturnOrThrow = true;
    saved.mergeDiamondFlow(_inferrer, thenLocals, _locals);
    _locals = saved;
    return null;
  }

  @override
  visitBreakStatement(ir.BreakStatement node) {
    JumpTarget target = _localsMap.getJumpTargetForBreak(node);
    _locals.seenBreakOrContinue = true;
    // Do a deep-copy of the locals, because the code following the
    // break will change them.
    if (_localsMap.generateContinueForBreak(node)) {
      _continuesFor[target].add(new LocalsHandler.deepCopyOf(_locals));
    } else {
      _breaksFor[target].add(new LocalsHandler.deepCopyOf(_locals));
    }
    return null;
  }

  @override
  visitLabeledStatement(ir.LabeledStatement node) {
    ir.Statement body = node.body;
    if (JumpVisitor.canBeBreakTarget(body)) {
      // Loops and switches handle their own labels.
      visit(body);
    } else {
      JumpTarget jumpTarget = _localsMap.getJumpTargetForLabel(node);
      _setupBreaksAndContinues(jumpTarget);
      visit(body);
      _locals.mergeAfterBreaks(_inferrer, _getBreaks(jumpTarget));
      _clearBreaksAndContinues(jumpTarget);
    }
    return null;
  }

  @override
  visitSwitchStatement(ir.SwitchStatement node) {
    visit(node.expression);

    JumpTarget jumpTarget = _localsMap.getJumpTargetForSwitch(node);
    _setupBreaksAndContinues(jumpTarget);

    List<JumpTarget> continueTargets = <JumpTarget>[];
    for (ir.SwitchCase switchCase in node.cases) {
      JumpTarget continueTarget =
          _localsMap.getJumpTargetForSwitchCase(switchCase);
      if (continueTarget != null) {
        continueTargets.add(continueTarget);
      }
    }
    if (continueTargets.isNotEmpty) {
      continueTargets.forEach(_setupBreaksAndContinues);

      // If the switch statement has a continue, we conservatively
      // visit all cases and update [locals] until we have reached a
      // fixed point.
      bool changed;
      _locals.startLoop(_inferrer, node);
      do {
        changed = false;
        for (ir.SwitchCase switchCase in node.cases) {
          LocalsHandler saved = _locals;
          _locals = new LocalsHandler.from(_locals, switchCase);
          visit(switchCase);
          changed = saved.mergeAll(_inferrer, [_locals]) || changed;
          _locals = saved;
        }
      } while (changed);
      _locals.endLoop(_inferrer, node);

      continueTargets.forEach(_clearBreaksAndContinues);
    } else {
      LocalsHandler saved = _locals;
      List<LocalsHandler> localsToMerge = <LocalsHandler>[];
      bool hasDefaultCase = false;

      for (ir.SwitchCase switchCase in node.cases) {
        if (switchCase.isDefault) {
          hasDefaultCase = true;
        }
        _locals = new LocalsHandler.from(saved, switchCase);
        visit(switchCase);
        localsToMerge.add(_locals);
      }
      saved.mergeAfterBreaks(_inferrer, localsToMerge,
          keepOwnLocals: !hasDefaultCase);
      _locals = saved;
    }
    _clearBreaksAndContinues(jumpTarget);
    return null;
  }

  @override
  visitSwitchCase(ir.SwitchCase node) {
    visit(node.body);
    return null;
  }

  @override
  visitContinueSwitchStatement(ir.ContinueSwitchStatement node) {
    JumpTarget target = _localsMap.getJumpTargetForContinueSwitch(node);
    _locals.seenBreakOrContinue = true;
    // Do a deep-copy of the locals, because the code following the
    // break will change them.
    _continuesFor[target].add(new LocalsHandler.deepCopyOf(_locals));
    return null;
  }

  @override
  TypeInformation visitListLiteral(ir.ListLiteral listLiteral) {
    // We only set the type once. We don't need to re-visit the children
    // when re-analyzing the node.
    return _inferrer.concreteTypes.putIfAbsent(listLiteral, () {
      TypeInformation elementType;
      int length = 0;
      for (ir.Expression element in listLiteral.expressions) {
        TypeInformation type = visit(element);
        elementType = elementType == null
            ? _types.allocatePhi(null, null, type, isTry: false)
            : _types.addPhiInput(null, elementType, type);
        length++;
      }
      elementType = elementType == null
          ? _types.nonNullEmpty()
          : _types.simplifyPhi(null, null, elementType);
      TypeInformation containerType =
          listLiteral.isConst ? _types.constListType : _types.growableListType;
      return _types.allocateList(
          containerType, listLiteral, _analyzedMember, elementType, length);
    });
  }

  @override
  TypeInformation visitMapLiteral(ir.MapLiteral node) {
    return _inferrer.concreteTypes.putIfAbsent(node, () {
      List keyTypes = <TypeInformation>[];
      List valueTypes = <TypeInformation>[];

      for (ir.MapEntry entry in node.entries) {
        keyTypes.add(visit(entry.key));
        valueTypes.add(visit(entry.value));
      }

      TypeInformation type =
          node.isConst ? _types.constMapType : _types.mapType;
      return _types.allocateMap(
          type, node, _analyzedMember, keyTypes, valueTypes);
    });
  }

  @override
  TypeInformation visitReturnStatement(ir.ReturnStatement node) {
    ir.Node expression = node.expression;
    recordReturnType(expression == null ? _types.nullType : visit(expression));
    _locals.seenReturnOrThrow = true;
    initializationIsIndefinite();
    return null;
  }

  @override
  TypeInformation visitBoolLiteral(ir.BoolLiteral node) {
    return _types.boolLiteralType(node.value);
  }

  @override
  TypeInformation visitIntLiteral(ir.IntLiteral node) {
    ConstantSystem constantSystem = _closedWorld.constantSystem;
    // The JavaScript backend may turn this literal into a double at
    // runtime.
    return _types.getConcreteTypeFor(_closedWorld.abstractValueDomain
        .computeAbstractValueForConstant(
            constantSystem.createIntFromInt(node.value)));
  }

  @override
  TypeInformation visitDoubleLiteral(ir.DoubleLiteral node) {
    ConstantSystem constantSystem = _closedWorld.constantSystem;
    // The JavaScript backend may turn this literal into an integer at
    // runtime.
    return _types.getConcreteTypeFor(_closedWorld.abstractValueDomain
        .computeAbstractValueForConstant(
            constantSystem.createDouble(node.value)));
  }

  @override
  TypeInformation visitStringLiteral(ir.StringLiteral node) {
    return _types.stringLiteralType(node.value);
  }

  @override
  TypeInformation visitStringConcatenation(ir.StringConcatenation node) {
    // Interpolation could have any effects since it could call any toString()
    // method.
    // TODO(sra): This could be modelled by a call to toString() but with a
    // guaranteed String return type.  Interpolation of known types would get
    // specialized effects.  This would not currently be effective since the JS
    // code in the toString methods for intercepted primitive types is assumed
    // to have all effects.  Effect annotations on JS code would be needed to
    // get the benefit.
    _sideEffectsBuilder.setAllSideEffects();

    node.visitChildren(this);
    return _types.stringType;
  }

  @override
  TypeInformation visitSymbolLiteral(ir.SymbolLiteral node) {
    return _types
        .nonNullSubtype(_closedWorld.commonElements.symbolImplementationClass);
  }

  @override
  TypeInformation visitTypeLiteral(ir.TypeLiteral node) {
    return _types.typeType;
  }

  @override
  TypeInformation visitVariableDeclaration(ir.VariableDeclaration node) {
    assert(
        node.parent is! ir.FunctionNode, "Unexpected parameter declaration.");
    Local local = _localsMap.getLocalVariable(node);
    DartType type = _localsMap.getLocalType(_elementMap, local);
    if (node.initializer == null) {
      _locals.update(_inferrer, local, _types.nullType, node, type);
    } else {
      _locals.update(_inferrer, local, visit(node.initializer), node, type);
    }
    if (node.initializer is ir.ThisExpression) {
      _markThisAsExposed();
    }
    return null;
  }

  @override
  TypeInformation visitVariableGet(ir.VariableGet node) {
    Local local = _localsMap.getLocalVariable(node.variable);
    TypeInformation type = _locals.use(_inferrer, local);
    assert(type != null, "Missing type information for $local.");
    return type;
  }

  @override
  TypeInformation visitVariableSet(ir.VariableSet node) {
    TypeInformation rhsType = visit(node.value);
    if (node.value is ir.ThisExpression) {
      _markThisAsExposed();
    }
    Local local = _localsMap.getLocalVariable(node.variable);
    DartType type = _localsMap.getLocalType(_elementMap, local);
    _locals.update(_inferrer, local, rhsType, node, type);
    return rhsType;
  }

  ArgumentsTypes analyzeArguments(ir.Arguments arguments) {
    List<TypeInformation> positional = <TypeInformation>[];
    Map<String, TypeInformation> named;
    for (ir.Expression argument in arguments.positional) {
      // TODO(ngeoffray): We could do better here if we knew what we
      // are calling does not expose this.
      if (argument is ir.ThisExpression) {
        _markThisAsExposed();
      }
      positional.add(visit(argument));
    }
    for (ir.NamedExpression argument in arguments.named) {
      named ??= <String, TypeInformation>{};
      ir.Expression value = argument.value;
      // TODO(ngeoffray): We could do better here if we knew what we
      // are calling does not expose this.
      if (value is ir.ThisExpression) {
        _markThisAsExposed();
      }
      named[argument.name] = visit(value);
    }

    return new ArgumentsTypes(positional, named);
  }

  @override
  TypeInformation visitMethodInvocation(ir.MethodInvocation node) {
    Selector selector = _elementMap.getSelector(node);
    AbstractValue mask = _memberData.typeOfSend(node);

    ir.TreeNode receiver = node.receiver;
    if (receiver is ir.VariableGet &&
        receiver.variable.parent is ir.FunctionDeclaration) {
      // This is an invocation of a named local function.
      ArgumentsTypes arguments = analyzeArguments(node.arguments);
      ClosureRepresentationInfo info =
          _closureDataLookup.getClosureInfo(receiver.variable.parent);
      if (isIncompatibleInvoke(info.callMethod, arguments)) {
        return _types.dynamicType;
      }

      TypeInformation type =
          handleStaticInvoke(node, selector, mask, info.callMethod, arguments);
      if (useStaticResultTypes) {
        type = _types.narrowType(type, _elementMap.getStaticType(node));
      }
      return type;
    }

    TypeInformation receiverType = visit(receiver);
    ArgumentsTypes arguments = analyzeArguments(node.arguments);
    if (selector.name == '==') {
      if (_types.isNull(receiverType)) {
        // null == o
        _potentiallyAddNullCheck(node, node.arguments.positional.first);
        return _types.boolType;
      } else if (_types.isNull(arguments.positional[0])) {
        // o == null
        _potentiallyAddNullCheck(node, node.receiver);
        return _types.boolType;
      }
    }
    if (node.receiver is ir.ThisExpression) {
      _checkIfExposesThis(
          selector, _types.newTypedSelector(receiverType, mask));
    }
    TypeInformation type = handleDynamicInvoke(
        CallType.access, node, selector, mask, receiverType, arguments);
    if (useStaticResultTypes) {
      type = _types.narrowType(type, _elementMap.getStaticType(node));
    }
    return type;
  }

  TypeInformation _handleDynamic(
      CallType callType,
      ir.Node node,
      Selector selector,
      AbstractValue mask,
      TypeInformation receiverType,
      ArgumentsTypes arguments) {
    assert(receiverType != null);
    if (_types.selectorNeedsUpdate(receiverType, mask)) {
      mask = receiverType == _types.dynamicType
          ? null
          : _types.newTypedSelector(receiverType, mask);
      _inferrer.updateSelectorInMember(
          _analyzedMember, callType, node, selector, mask);
    }

    ir.VariableDeclaration variable;
    if (node is ir.MethodInvocation && node.receiver is ir.VariableGet) {
      ir.VariableGet get = node.receiver;
      variable = get.variable;
    } else if (node is ir.PropertyGet && node.receiver is ir.VariableGet) {
      ir.VariableGet get = node.receiver;
      variable = get.variable;
    } else if (node is ir.PropertySet && node.receiver is ir.VariableGet) {
      ir.VariableGet get = node.receiver;
      variable = get.variable;
    }

    if (variable != null) {
      Local local = _localsMap.getLocalVariable(variable);
      if (!_capturedVariables.contains(local)) {
        TypeInformation refinedType = _types
            .refineReceiver(selector, mask, receiverType, isConditional: false);
        DartType type = _localsMap.getLocalType(_elementMap, local);
        _locals.update(_inferrer, local, refinedType, node, type);
        List<Refinement> refinements = _localRefinementMap[variable];
        if (refinements != null) {
          refinements.add(new Refinement(selector, mask));
        }
      }
    }

    return _inferrer.registerCalledSelector(callType, node, selector, mask,
        receiverType, _analyzedMember, arguments, _sideEffectsBuilder,
        inLoop: inLoop, isConditional: false);
  }

  TypeInformation handleDynamicGet(ir.Node node, Selector selector,
      AbstractValue mask, TypeInformation receiverType) {
    return _handleDynamic(
        CallType.access, node, selector, mask, receiverType, null);
  }

  TypeInformation handleDynamicSet(
      ir.Node node,
      Selector selector,
      AbstractValue mask,
      TypeInformation receiverType,
      TypeInformation rhsType) {
    ArgumentsTypes arguments = new ArgumentsTypes([rhsType], null);
    return _handleDynamic(
        CallType.access, node, selector, mask, receiverType, arguments);
  }

  TypeInformation handleDynamicInvoke(
      CallType callType,
      ir.Node node,
      Selector selector,
      AbstractValue mask,
      TypeInformation receiverType,
      ArgumentsTypes arguments) {
    return _handleDynamic(
        callType, node, selector, mask, receiverType, arguments);
  }

  /// Map from synthesized variables created for non-null operations to observed
  /// refinements. This is used to refine locals in cases like:
  ///
  ///     local?.method()
  ///
  /// which in kernel is encoded as
  ///
  ///     let #t1 = local in #t1 == null ? null : #1.method()
  ///
  Map<ir.VariableDeclaration, List<Refinement>> _localRefinementMap =
      <ir.VariableDeclaration, List<Refinement>>{};

  @override
  TypeInformation visitLet(ir.Let node) {
    ir.VariableDeclaration alias;
    ir.Expression body = node.body;
    if (node.variable.name == null &&
        node.variable.isFinal &&
        node.variable.initializer is ir.VariableGet &&
        body is ir.ConditionalExpression &&
        body.condition is ir.MethodInvocation &&
        body.then is ir.NullLiteral) {
      ir.VariableGet get = node.variable.initializer;
      ir.MethodInvocation invocation = body.condition;
      ir.Expression receiver = invocation.receiver;
      if (invocation.name.name == '==' &&
          receiver is ir.VariableGet &&
          receiver.variable == node.variable &&
          invocation.arguments.positional.single is ir.NullLiteral) {
        // We have
        //   let #t1 = local in #t1 == null ? null : e
        alias = get.variable;
        _localRefinementMap[node.variable] = <Refinement>[];
      }
    }
    visit(node.variable);
    TypeInformation type = visit(body);
    if (alias != null) {
      List<Refinement> refinements = _localRefinementMap.remove(node.variable);
      if (refinements.isNotEmpty) {
        Local local = _localsMap.getLocalVariable(alias);
        DartType type = _localsMap.getLocalType(_elementMap, local);
        TypeInformation localType = _locals.use(_inferrer, local);
        for (Refinement refinement in refinements) {
          localType = _types.refineReceiver(
              refinement.selector, refinement.mask, localType,
              isConditional: true);
          _locals.update(_inferrer, local, localType, node, type);
        }
      }
    }
    return type;
  }

  @override
  TypeInformation visitForInStatement(ir.ForInStatement node) {
    if (node.iterable is ir.ThisExpression) {
      // Any reasonable implementation of an iterator would expose
      // this, so we play it safe and assume it will.
      _markThisAsExposed();
    }

    AbstractValue currentMask;
    AbstractValue moveNextMask;
    TypeInformation iteratorType;
    if (node.isAsync) {
      TypeInformation expressionType = visit(node.iterable);

      currentMask = _memberData.typeOfIteratorCurrent(node);
      moveNextMask = _memberData.typeOfIteratorMoveNext(node);

      ConstructorEntity constructor =
          _closedWorld.commonElements.streamIteratorConstructor;

      /// Synthesize a call to the [StreamIterator] constructor.
      iteratorType = handleStaticInvoke(node, null, null, constructor,
          new ArgumentsTypes([expressionType], null));
    } else {
      TypeInformation expressionType = visit(node.iterable);
      Selector iteratorSelector = Selectors.iterator;
      AbstractValue iteratorMask = _memberData.typeOfIterator(node);
      currentMask = _memberData.typeOfIteratorCurrent(node);
      moveNextMask = _memberData.typeOfIteratorMoveNext(node);

      iteratorType = handleDynamicInvoke(CallType.forIn, node, iteratorSelector,
          iteratorMask, expressionType, new ArgumentsTypes.empty());
    }

    handleDynamicInvoke(CallType.forIn, node, Selectors.moveNext, moveNextMask,
        iteratorType, new ArgumentsTypes.empty());
    TypeInformation currentType = handleDynamicInvoke(
        CallType.forIn,
        node,
        Selectors.current,
        currentMask,
        iteratorType,
        new ArgumentsTypes.empty());

    Local variable = _localsMap.getLocalVariable(node.variable);
    DartType variableType = _localsMap.getLocalType(_elementMap, variable);
    _locals.update(
        _inferrer, variable, currentType, node.variable, variableType);

    JumpTarget target = _localsMap.getJumpTargetForForIn(node);
    return handleLoop(node, target, () {
      visit(node.body);
    });
  }

  void _setupBreaksAndContinues(JumpTarget target) {
    if (target == null) return;
    if (target.isContinueTarget) {
      _continuesFor[target] = <LocalsHandler>[];
    }
    if (target.isBreakTarget) {
      _breaksFor[target] = <LocalsHandler>[];
    }
  }

  void _clearBreaksAndContinues(JumpTarget element) {
    _continuesFor.remove(element);
    _breaksFor.remove(element);
  }

  List<LocalsHandler> _getBreaks(JumpTarget target) {
    List<LocalsHandler> list = <LocalsHandler>[_locals];
    if (target == null) return list;
    if (!target.isBreakTarget) return list;
    return list..addAll(_breaksFor[target]);
  }

  List<LocalsHandler> _getLoopBackEdges(JumpTarget target) {
    List<LocalsHandler> list = <LocalsHandler>[_locals];
    if (target == null) return list;
    if (!target.isContinueTarget) return list;
    return list..addAll(_continuesFor[target]);
  }

  TypeInformation handleLoop(ir.Node node, JumpTarget target, void logic()) {
    _loopLevel++;
    bool changed = false;
    LocalsHandler saved = _locals;
    saved.startLoop(_inferrer, node);
    do {
      // Setup (and clear in case of multiple iterations of the loop)
      // the lists of breaks and continues seen in the loop.
      _setupBreaksAndContinues(target);
      _locals = new LocalsHandler.from(saved, node);
      logic();
      changed = saved.mergeAll(_inferrer, _getLoopBackEdges(target));
    } while (changed);
    _loopLevel--;
    saved.endLoop(_inferrer, node);
    bool keepOwnLocals = node is! ir.DoStatement;
    saved.mergeAfterBreaks(_inferrer, _getBreaks(target),
        keepOwnLocals: keepOwnLocals);
    _locals = saved;
    _clearBreaksAndContinues(target);
    return null;
  }

  @override
  TypeInformation visitConstructorInvocation(ir.ConstructorInvocation node) {
    ConstructorEntity constructor = _elementMap.getConstructor(node.target);
    ArgumentsTypes arguments = analyzeArguments(node.arguments);
    Selector selector = _elementMap.getSelector(node);
    AbstractValue mask = _memberData.typeOfSend(node);
    return handleConstructorInvoke(
        node, node.arguments, selector, mask, constructor, arguments);
  }

  /// Try to find the length given to a fixed array constructor call.
  int _findLength(ir.Arguments arguments) {
    ir.Expression firstArgument = arguments.positional.first;
    if (firstArgument is ir.IntLiteral) {
      return firstArgument.value;
    } else if (firstArgument is ir.StaticGet) {
      MemberEntity member = _elementMap.getMember(firstArgument.target);
      if (member.isField &&
          (member.isStatic || member.isTopLevel) &&
          _closedWorld.fieldNeverChanges(member)) {
        ConstantValue value = _elementMap.getFieldConstantValue(member);
        if (value != null && value.isInt) {
          IntConstantValue intValue = value;
          return intValue.intValue.toInt();
        }
      }
    }
    return null;
  }

  /// Returns `true` if
  bool _isConstructorOfTypedArraySubclass(ConstructorEntity constructor) {
    ClassEntity cls = constructor.enclosingClass;
    return cls.library.canonicalUri == Uris.dart__native_typed_data &&
        _closedWorld.nativeData.isNativeClass(cls) &&
        _closedWorld.classHierarchy
            .isSubtypeOf(cls, _closedWorld.commonElements.typedDataClass) &&
        _closedWorld.classHierarchy
            .isSubtypeOf(cls, _closedWorld.commonElements.listClass) &&
        constructor.name == '';
  }

  TypeInformation handleConstructorInvoke(
      ir.Node node,
      ir.Arguments arguments,
      Selector selector,
      AbstractValue mask,
      ConstructorEntity constructor,
      ArgumentsTypes argumentsTypes) {
    TypeInformation returnType =
        handleStaticInvoke(node, selector, mask, constructor, argumentsTypes);
    if (_elementMap.commonElements.isUnnamedListConstructor(constructor)) {
      // We have `new List(...)`.
      if (arguments.positional.isEmpty && arguments.named.isEmpty) {
        // We have `new List()`.
        return _inferrer.concreteTypes.putIfAbsent(
            node,
            () => _types.allocateList(_types.growableListType, node,
                _analyzedMember, _types.nonNullEmpty(), 0));
      } else {
        // We have `new List(len)`.
        int length = _findLength(arguments);
        return _inferrer.concreteTypes.putIfAbsent(
            node,
            () => _types.allocateList(_types.fixedListType, node,
                _analyzedMember, _types.nullType, length));
      }
    } else if (_elementMap.commonElements
        .isFilledListConstructor(constructor)) {
      // We have `new Uint32List(len, fill)`.
      int length = _findLength(arguments);
      TypeInformation elementType = argumentsTypes.positional[1];

      return _inferrer.concreteTypes.putIfAbsent(
          node,
          () => _types.allocateList(_types.fixedListType, node, _analyzedMember,
              elementType, length));
    } else if (_isConstructorOfTypedArraySubclass(constructor)) {
      // We have something like `new List.filled(len, fill)`.
      int length = _findLength(arguments);
      MemberEntity member = _elementMap.elementEnvironment
          .lookupClassMember(constructor.enclosingClass, '[]');
      TypeInformation elementType = _inferrer.returnTypeOfMember(member);
      return _inferrer.concreteTypes.putIfAbsent(
          node,
          () => _types.allocateList(
              _types.nonNullExact(constructor.enclosingClass),
              node,
              _analyzedMember,
              elementType,
              length));
    } else {
      return returnType;
    }
  }

  TypeInformation handleStaticInvoke(ir.Node node, Selector selector,
      AbstractValue mask, MemberEntity element, ArgumentsTypes arguments) {
    return _inferrer.registerCalledMember(node, selector, mask, _analyzedMember,
        element, arguments, _sideEffectsBuilder, inLoop);
  }

  TypeInformation handleClosureCall(ir.Node node, Selector selector,
      AbstractValue mask, MemberEntity member, ArgumentsTypes arguments) {
    return _inferrer.registerCalledClosure(
        node,
        selector,
        mask,
        _inferrer.typeOfMember(member),
        _analyzedMember,
        arguments,
        _sideEffectsBuilder,
        inLoop: inLoop);
  }

  TypeInformation handleForeignInvoke(
      ir.StaticInvocation node,
      FunctionEntity function,
      ArgumentsTypes arguments,
      Selector selector,
      AbstractValue mask) {
    String name = function.name;
    handleStaticInvoke(node, selector, mask, function, arguments);
    if (name == JavaScriptBackend.JS) {
      NativeBehavior nativeBehavior =
          _elementMap.getNativeBehaviorForJsCall(node);
      _sideEffectsBuilder.add(nativeBehavior.sideEffects);
      return _inferrer.typeOfNativeBehavior(nativeBehavior);
    } else if (name == JavaScriptBackend.JS_EMBEDDED_GLOBAL) {
      NativeBehavior nativeBehavior =
          _elementMap.getNativeBehaviorForJsEmbeddedGlobalCall(node);
      _sideEffectsBuilder.add(nativeBehavior.sideEffects);
      return _inferrer.typeOfNativeBehavior(nativeBehavior);
    } else if (name == JavaScriptBackend.JS_BUILTIN) {
      NativeBehavior nativeBehavior =
          _elementMap.getNativeBehaviorForJsBuiltinCall(node);
      _sideEffectsBuilder.add(nativeBehavior.sideEffects);
      return _inferrer.typeOfNativeBehavior(nativeBehavior);
    } else if (name == JavaScriptBackend.JS_STRING_CONCAT) {
      return _types.stringType;
    } else {
      _sideEffectsBuilder.setAllSideEffects();
      return _types.dynamicType;
    }
  }

  @override
  TypeInformation visitStaticInvocation(ir.StaticInvocation node) {
    MemberEntity member = _elementMap.getMember(node.target);
    ArgumentsTypes arguments = analyzeArguments(node.arguments);
    Selector selector = _elementMap.getSelector(node);
    AbstractValue mask = _memberData.typeOfSend(node);
    if (_closedWorld.commonElements.isForeign(member)) {
      return handleForeignInvoke(node, member, arguments, selector, mask);
    } else if (member.isConstructor) {
      return handleConstructorInvoke(
          node, node.arguments, selector, mask, member, arguments);
    } else if (member.isFunction) {
      TypeInformation type =
          handleStaticInvoke(node, selector, mask, member, arguments);
      if (useStaticResultTypes) {
        type = _types.narrowType(type, _elementMap.getStaticType(node));
      }
      return type;
    } else {
      TypeInformation type =
          handleClosureCall(node, selector, mask, member, arguments);
      if (useStaticResultTypes) {
        type = _types.narrowType(type, _elementMap.getStaticType(node));
      }
      return type;
    }
  }

  @override
  TypeInformation visitLoadLibrary(ir.LoadLibrary node) {
    // TODO(johnniwinther): Improve this by returning a Future type instead.
    return _types.dynamicType;
  }

  @override
  TypeInformation visitStaticGet(ir.StaticGet node) {
    MemberEntity member = _elementMap.getMember(node.target);
    AbstractValue mask = _memberData.typeOfSend(node);
    TypeInformation type = handleStaticInvoke(
        node, new Selector.getter(member.memberName), mask, member, null);
    if (useStaticResultTypes) {
      type = _types.narrowType(type, _elementMap.getStaticType(node));
    }
    return type;
  }

  @override
  TypeInformation visitStaticSet(ir.StaticSet node) {
    TypeInformation rhsType = visit(node.value);
    if (node.value is ir.ThisExpression) {
      _markThisAsExposed();
    }
    MemberEntity member = _elementMap.getMember(node.target);
    AbstractValue mask = _memberData.typeOfSend(node);
    handleStaticInvoke(node, new Selector.setter(member.memberName), mask,
        member, new ArgumentsTypes([rhsType], null));
    return rhsType;
  }

  @override
  TypeInformation visitPropertyGet(ir.PropertyGet node) {
    TypeInformation receiverType = visit(node.receiver);
    Selector selector = _elementMap.getSelector(node);
    AbstractValue mask = _memberData.typeOfSend(node);
    // TODO(johnniwinther): Use `node.interfaceTarget` to narrow the receiver
    // type for --trust-type-annotations/strong-mode.
    if (node.receiver is ir.ThisExpression) {
      _checkIfExposesThis(
          selector, _types.newTypedSelector(receiverType, mask));
    }
    TypeInformation type = handleDynamicGet(node, selector, mask, receiverType);
    if (useStaticResultTypes) {
      type = _types.narrowType(type, _elementMap.getStaticType(node));
    }
    return type;
  }

  @override
  TypeInformation visitDirectPropertyGet(ir.DirectPropertyGet node) {
    TypeInformation receiverType = thisType;
    MemberEntity member = _elementMap.getMember(node.target);
    AbstractValue mask = _memberData.typeOfSend(node);
    // TODO(johnniwinther): Use `node.target` to narrow the receiver type.
    Selector selector = new Selector.getter(member.memberName);
    _checkIfExposesThis(selector, _types.newTypedSelector(receiverType, mask));
    TypeInformation type = handleDynamicGet(node, selector, mask, receiverType);
    if (useStaticResultTypes) {
      type = _types.narrowType(type, _elementMap.getStaticType(node));
    }
    return type;
  }

  @override
  TypeInformation visitPropertySet(ir.PropertySet node) {
    TypeInformation receiverType = visit(node.receiver);
    Selector selector = _elementMap.getSelector(node);
    AbstractValue mask = _memberData.typeOfSend(node);

    TypeInformation rhsType = visit(node.value);
    if (node.value is ir.ThisExpression) {
      _markThisAsExposed();
    }

    if (_inGenerativeConstructor && node.receiver is ir.ThisExpression) {
      AbstractValue typedMask = _types.newTypedSelector(receiverType, mask);
      if (!_closedWorld.includesClosureCall(selector, typedMask)) {
        Iterable<MemberEntity> targets =
            _closedWorld.locateMembers(selector, typedMask);
        // We just recognized a field initialization of the form:
        // `this.foo = 42`. If there is only one target, we can update
        // its type.
        if (targets.length == 1) {
          MemberEntity single = targets.first;
          if (single.isField) {
            FieldEntity field = single;
            _locals.updateField(field, rhsType);
          }
        }
      }
    }
    if (node.receiver is ir.ThisExpression) {
      _checkIfExposesThis(
          selector, _types.newTypedSelector(receiverType, mask));
    }
    handleDynamicSet(node, selector, mask, receiverType, rhsType);
    return rhsType;
  }

  @override
  TypeInformation visitThisExpression(ir.ThisExpression node) {
    return thisType;
  }

  bool handleCondition(
      ir.Node node, List<IsCheck> positiveTests, List<IsCheck> negativeTests) {
    bool oldConditionIsSimple = _conditionIsSimple;
    bool oldAccumulateIsChecks = _accumulateIsChecks;
    List<IsCheck> oldPositiveIsChecks = _positiveIsChecks;
    List<IsCheck> oldNegativeIsChecks = _negativeIsChecks;
    _accumulateIsChecks = true;
    _conditionIsSimple = true;
    _positiveIsChecks = positiveTests;
    _negativeIsChecks = negativeTests;
    visit(node, conditionContext: true);
    bool simpleCondition = _conditionIsSimple;
    _accumulateIsChecks = oldAccumulateIsChecks;
    _positiveIsChecks = oldPositiveIsChecks;
    _negativeIsChecks = oldNegativeIsChecks;
    _conditionIsSimple = oldConditionIsSimple;
    return simpleCondition;
  }

  void _potentiallyAddIsCheck(ir.IsExpression node) {
    if (!_accumulateIsChecks) return;
    ir.Expression operand = node.operand;
    if (operand is ir.VariableGet) {
      _positiveIsChecks.add(new IsCheck(
          node,
          _localsMap.getLocalVariable(operand.variable),
          _elementMap.getDartType(node.type)));
    }
  }

  void _potentiallyAddNullCheck(
      ir.MethodInvocation node, ir.Expression receiver) {
    if (!_accumulateIsChecks) return;
    if (receiver is ir.VariableGet) {
      _positiveIsChecks.add(new IsCheck(
          node, _localsMap.getLocalVariable(receiver.variable), null));
    }
  }

  void _updateIsChecks(
      List<IsCheck> positiveTests, List<IsCheck> negativeTests) {
    for (IsCheck check in positiveTests) {
      if (check.type != null) {
        _locals.narrow(_inferrer, check.local, check.type, check.node);
      } else {
        DartType localType = _localsMap.getLocalType(_elementMap, check.local);
        _locals.update(
            _inferrer, check.local, _types.nullType, check.node, localType);
      }
    }
    for (IsCheck check in negativeTests) {
      if (check.type != null) {
        // TODO(johnniwinther): Use negative type knowledge.
      } else {
        _locals.narrow(_inferrer, check.local,
            _closedWorld.commonElements.objectType, check.node);
      }
    }
  }

  @override
  TypeInformation visitIfStatement(ir.IfStatement node) {
    List<IsCheck> positiveTests = <IsCheck>[];
    List<IsCheck> negativeTests = <IsCheck>[];
    bool simpleCondition =
        handleCondition(node.condition, positiveTests, negativeTests);
    LocalsHandler saved = _locals;
    _locals = new LocalsHandler.from(_locals, node);
    _updateIsChecks(positiveTests, negativeTests);
    visit(node.then);
    LocalsHandler thenLocals = _locals;
    _locals = new LocalsHandler.from(saved, node);
    if (simpleCondition) {
      _updateIsChecks(negativeTests, positiveTests);
    }
    visit(node.otherwise);
    saved.mergeDiamondFlow(_inferrer, thenLocals, _locals);
    _locals = saved;
    return null;
  }

  @override
  TypeInformation visitIsExpression(ir.IsExpression node) {
    _potentiallyAddIsCheck(node);
    visit(node.operand);
    return _types.boolType;
  }

  @override
  TypeInformation visitNot(ir.Not node) {
    List<IsCheck> temp = _positiveIsChecks;
    _positiveIsChecks = _negativeIsChecks;
    _negativeIsChecks = temp;
    visit(node.operand, conditionContext: _accumulateIsChecks);
    temp = _positiveIsChecks;
    _positiveIsChecks = _negativeIsChecks;
    _negativeIsChecks = temp;
    return _types.boolType;
  }

  @override
  TypeInformation visitLogicalExpression(ir.LogicalExpression node) {
    if (node.operator == '&&') {
      _conditionIsSimple = false;
      bool oldAccumulateIsChecks = _accumulateIsChecks;
      List<IsCheck> oldPositiveIsChecks = _positiveIsChecks;
      List<IsCheck> oldNegativeIsChecks = _negativeIsChecks;
      if (!_accumulateIsChecks) {
        _accumulateIsChecks = true;
        _positiveIsChecks = <IsCheck>[];
        _negativeIsChecks = <IsCheck>[];
      }
      visit(node.left, conditionContext: _accumulateIsChecks);
      LocalsHandler saved = _locals;
      _locals = new LocalsHandler.from(_locals, node);
      _updateIsChecks(_positiveIsChecks, _negativeIsChecks);
      LocalsHandler narrowed;
      if (oldAccumulateIsChecks) {
        narrowed = new LocalsHandler.topLevelCopyOf(_locals);
      } else {
        _accumulateIsChecks = false;
        _positiveIsChecks = oldPositiveIsChecks;
        _negativeIsChecks = oldNegativeIsChecks;
      }
      visit(node.right, conditionContext: _accumulateIsChecks);
      if (oldAccumulateIsChecks) {
        bool invalidatedInRightHandSide(IsCheck check) {
          return narrowed.locals[check.local] != _locals.locals[check.local];
        }

        _positiveIsChecks.removeWhere(invalidatedInRightHandSide);
        _negativeIsChecks.removeWhere(invalidatedInRightHandSide);
      }
      saved.mergeDiamondFlow(_inferrer, _locals, null);
      _locals = saved;
      return _types.boolType;
    } else if (node.operator == '||') {
      _conditionIsSimple = false;
      List<IsCheck> positiveIsChecks = <IsCheck>[];
      List<IsCheck> negativeIsChecks = <IsCheck>[];
      bool isSimple =
          handleCondition(node.left, positiveIsChecks, negativeIsChecks);
      LocalsHandler saved = _locals;
      _locals = new LocalsHandler.from(_locals, node);
      if (isSimple) {
        _updateIsChecks(negativeIsChecks, positiveIsChecks);
      }
      visit(node.right, conditionContext: false);
      saved.mergeDiamondFlow(_inferrer, _locals, null);
      _locals = saved;
      return _types.boolType;
    }
    failedAt(CURRENT_ELEMENT_SPANNABLE,
        "Unexpected logical operator '${node.operator}'.");
    return null;
  }

  @override
  TypeInformation visitConditionalExpression(ir.ConditionalExpression node) {
    List<IsCheck> positiveTests = <IsCheck>[];
    List<IsCheck> negativeTests = <IsCheck>[];
    bool simpleCondition =
        handleCondition(node.condition, positiveTests, negativeTests);
    LocalsHandler saved = _locals;
    _locals = new LocalsHandler.from(_locals, node);
    _updateIsChecks(positiveTests, negativeTests);
    TypeInformation firstType = visit(node.then);
    LocalsHandler thenLocals = _locals;
    _locals = new LocalsHandler.from(saved, node);
    if (simpleCondition) _updateIsChecks(negativeTests, positiveTests);
    TypeInformation secondType = visit(node.otherwise);
    saved.mergeDiamondFlow(_inferrer, thenLocals, _locals);
    _locals = saved;
    return _types.allocateDiamondPhi(firstType, secondType);
  }

  TypeInformation handleLocalFunction(
      ir.TreeNode node, ir.FunctionNode functionNode,
      [ir.VariableDeclaration variable]) {
    // We loose track of [this] in closures (see issue 20840). To be on
    // the safe side, we mark [this] as exposed here. We could do better by
    // analyzing the closure.
    // TODO(herhut): Analyze whether closure exposes this. Possibly using
    // whether the created closure as a `thisLocal`.
    _markThisAsExposed();

    ClosureRepresentationInfo info = _closureDataLookup.getClosureInfo(node);

    // Record the types of captured non-boxed variables. Types of
    // these variables may already be there, because of an analysis of
    // a previous closure.
    info.forEachFreeVariable((variable, field) {
      if (!info.isVariableBoxed(variable)) {
        if (variable == info.thisLocal) {
          _inferrer.recordTypeOfField(field, thisType);
        }
        // The type is null for type parameters.
        if (_locals.locals[variable] == null) return;
        _inferrer.recordTypeOfField(field, _locals.locals[variable]);
      }
      _capturedVariables.add(variable);
    });

    TypeInformation localFunctionType =
        _inferrer.concreteTypes.putIfAbsent(node, () {
      return _types.allocateClosure(info.callMethod);
    });
    if (variable != null) {
      Local local = _localsMap.getLocalVariable(variable);
      DartType type = _localsMap.getLocalType(_elementMap, local);
      _locals.update(_inferrer, local, localFunctionType, node, type);
    }

    // We don't put the closure in the work queue of the
    // inferrer, because it will share information with its enclosing
    // method, like for example the types of local variables.
    LocalsHandler closureLocals =
        new LocalsHandler.from(_locals, node, useOtherTryBlock: false);
    KernelTypeGraphBuilder visitor = new KernelTypeGraphBuilder(
        _options,
        _closedWorld,
        _inferrer,
        info.callMethod,
        functionNode,
        _localsMap,
        closureLocals);
    visitor.run();
    _inferrer.recordReturnType(info.callMethod, visitor._returnType);

    return localFunctionType;
  }

  @override
  TypeInformation visitFunctionDeclaration(ir.FunctionDeclaration node) {
    return handleLocalFunction(node, node.function, node.variable);
  }

  @override
  TypeInformation visitFunctionExpression(ir.FunctionExpression node) {
    return handleLocalFunction(node, node.function);
  }

  @override
  visitWhileStatement(ir.WhileStatement node) {
    return handleLoop(node, _localsMap.getJumpTargetForWhile(node), () {
      List<IsCheck> positiveTests = <IsCheck>[];
      List<IsCheck> negativeTests = <IsCheck>[];
      handleCondition(node.condition, positiveTests, negativeTests);
      _updateIsChecks(positiveTests, negativeTests);
      visit(node.body);
    });
  }

  @override
  visitDoStatement(ir.DoStatement node) {
    return handleLoop(node, _localsMap.getJumpTargetForDo(node), () {
      visit(node.body);
      List<IsCheck> positiveTests = <IsCheck>[];
      List<IsCheck> negativeTests = <IsCheck>[];
      handleCondition(node.condition, positiveTests, negativeTests);
      // TODO(29309): This condition appears to strengthen both the back-edge
      // and exit-edge. For now, avoid strengthening on the condition until the
      // proper fix is found.
      //
      //     updateIsChecks(positiveTests, negativeTests);
    });
  }

  @override
  visitForStatement(ir.ForStatement node) {
    for (ir.VariableDeclaration variable in node.variables) {
      visit(variable);
    }
    return handleLoop(node, _localsMap.getJumpTargetForFor(node), () {
      List<IsCheck> positiveTests = <IsCheck>[];
      List<IsCheck> negativeTests = <IsCheck>[];
      handleCondition(node.condition, positiveTests, negativeTests);
      _updateIsChecks(positiveTests, negativeTests);
      visit(node.body);
      for (ir.Expression update in node.updates) {
        visit(update);
      }
    });
  }

  @override
  visitTryCatch(ir.TryCatch node) {
    LocalsHandler saved = _locals;
    _locals = new LocalsHandler.from(_locals, node,
        isTry: true, useOtherTryBlock: false);
    initializationIsIndefinite();
    visit(node.body);
    saved.mergeDiamondFlow(_inferrer, _locals, null);
    _locals = saved;
    for (ir.Catch catchBlock in node.catches) {
      saved = _locals;
      _locals = new LocalsHandler.from(_locals, catchBlock);
      visit(catchBlock);
      saved.mergeDiamondFlow(_inferrer, _locals, null);
      _locals = saved;
    }
    return null;
  }

  @override
  visitTryFinally(ir.TryFinally node) {
    LocalsHandler saved = _locals;
    _locals = new LocalsHandler.from(_locals, node,
        isTry: true, useOtherTryBlock: false);
    initializationIsIndefinite();
    visit(node.body);
    saved.mergeDiamondFlow(_inferrer, _locals, null);
    _locals = saved;
    visit(node.finalizer);
    return null;
  }

  @override
  visitCatch(ir.Catch node) {
    ir.VariableDeclaration exception = node.exception;
    if (exception != null) {
      TypeInformation mask;
      DartType type = node.guard != null
          ? _elementMap.getDartType(node.guard)
          : const DynamicType();
      if (type.isInterfaceType) {
        InterfaceType interfaceType = type;
        mask = _types.nonNullSubtype(interfaceType.element);
      } else {
        mask = _types.dynamicType;
      }
      Local local = _localsMap.getLocalVariable(exception);
      _locals.update(_inferrer, local, mask, node, const DynamicType());
    }
    ir.VariableDeclaration stackTrace = node.stackTrace;
    if (stackTrace != null) {
      Local local = _localsMap.getLocalVariable(stackTrace);
      // TODO(johnniwinther): Use a mask based on [StackTrace].
      _locals.update(
          _inferrer, local, _types.dynamicType, node, const DynamicType());
    }
    visit(node.body);
    return null;
  }

  @override
  TypeInformation visitThrow(ir.Throw node) {
    visit(node.expression);
    _locals.seenReturnOrThrow = true;
    return _types.nonNullEmpty();
  }

  @override
  TypeInformation visitRethrow(ir.Rethrow node) {
    _locals.seenReturnOrThrow = true;
    return _types.nonNullEmpty();
  }

  TypeInformation handleSuperNoSuchMethod(ir.Node node, Selector selector,
      AbstractValue mask, ArgumentsTypes arguments) {
    // Ensure we create a node, to make explicit the call to the
    // `noSuchMethod` handler.
    FunctionEntity noSuchMethod =
        _elementMap.getSuperNoSuchMethod(_analyzedMember.enclosingClass);
    return handleStaticInvoke(node, selector, mask, noSuchMethod, arguments);
  }

  @override
  TypeInformation visitSuperPropertyGet(ir.SuperPropertyGet node) {
    // TODO(herhut): We could do better here if we knew what we
    // are calling does not expose this.
    _markThisAsExposed();

    MemberEntity member =
        _elementMap.getSuperMember(_analyzedMember, node.name);
    AbstractValue mask = _memberData.typeOfSend(node);
    Selector selector = new Selector.getter(_elementMap.getName(node.name));
    if (member == null) {
      return handleSuperNoSuchMethod(node, selector, mask, null);
    } else {
      TypeInformation type =
          handleStaticInvoke(node, selector, mask, member, null);
      if (useStaticResultTypes) {
        type = _types.narrowType(type, _elementMap.getStaticType(node));
      }
      return type;
    }
  }

  @override
  TypeInformation visitSuperPropertySet(ir.SuperPropertySet node) {
    // TODO(herhut): We could do better here if we knew what we
    // are calling does not expose this.
    _markThisAsExposed();

    TypeInformation rhsType = visit(node.value);
    MemberEntity member =
        _elementMap.getSuperMember(_analyzedMember, node.name, setter: true);
    AbstractValue mask = _memberData.typeOfSend(node);
    Selector selector = new Selector.setter(_elementMap.getName(node.name));
    ArgumentsTypes arguments = new ArgumentsTypes([rhsType], null);
    if (member == null) {
      return handleSuperNoSuchMethod(node, selector, mask, arguments);
    } else {
      handleStaticInvoke(node, selector, mask, member, arguments);
      return rhsType;
    }
  }

  @override
  TypeInformation visitSuperMethodInvocation(ir.SuperMethodInvocation node) {
    // TODO(herhut): We could do better here if we knew what we
    // are calling does not expose this.
    _markThisAsExposed();

    MemberEntity member =
        _elementMap.getSuperMember(_analyzedMember, node.name);
    ArgumentsTypes arguments = analyzeArguments(node.arguments);
    Selector selector = _elementMap.getSelector(node);
    AbstractValue mask = _memberData.typeOfSend(node);
    if (member == null) {
      return handleSuperNoSuchMethod(node, selector, mask, arguments);
    } else if (member.isFunction) {
      if (isIncompatibleInvoke(member, arguments)) {
        return handleSuperNoSuchMethod(node, selector, mask, arguments);
      } else {
        TypeInformation type =
            handleStaticInvoke(node, selector, mask, member, arguments);
        if (useStaticResultTypes) {
          type = _types.narrowType(type, _elementMap.getStaticType(node));
        }
        return type;
      }
    } else {
      TypeInformation type =
          handleClosureCall(node, selector, mask, member, arguments);
      if (useStaticResultTypes) {
        type = _types.narrowType(type, _elementMap.getStaticType(node));
      }
      return type;
    }
  }

  @override
  TypeInformation visitAsExpression(ir.AsExpression node) {
    TypeInformation operandType = visit(node.operand);
    return _types.narrowType(operandType, _elementMap.getDartType(node.type));
  }

  @override
  TypeInformation visitAwaitExpression(ir.AwaitExpression node) {
    TypeInformation futureType = visit(node.operand);
    return _inferrer.registerAwait(node, futureType);
  }

  @override
  TypeInformation visitYieldStatement(ir.YieldStatement node) {
    TypeInformation operandType = visit(node.expression);
    return _inferrer.registerYield(node, operandType);
  }

  @override
  TypeInformation visitCheckLibraryIsLoaded(ir.CheckLibraryIsLoaded node) {
    return _types.nonNullEmpty();
  }

  @override
  TypeInformation visitInvalidExpression(ir.InvalidExpression node) {
    // TODO(johnniwinther): Maybe this should be [empty] instead?
    return _types.dynamicType;
  }
}

class IsCheck {
  final ir.Expression node;
  final Local local;
  final DartType type;

  IsCheck(this.node, this.local, this.type);

  String toString() => 'IsCheck($local,$type)';
}

class Refinement {
  final Selector selector;
  final AbstractValue mask;

  Refinement(this.selector, this.mask);
}
