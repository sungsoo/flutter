// Copyright 2016 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:flutter/foundation.dart';

class _AsyncScope {
  _AsyncScope(this.creationStack, this.zone);
  final StackTrace creationStack;
  final Zone zone;
}

/// Utility class for all the async APIs in the `flutter_test` library.
///
/// This class provides checking for asynchronous APIs, allowing the library to
/// verify that all the asynchronous APIs are properly `await`ed before calling
/// another.
///
/// For example, it prevents this kind of code:
///
/// ```dart
/// tester.pump(); // forgot to call "await"!
/// tester.pump();
/// ```
///
/// ...by detecting, in the second call to `pump`, that it should actually be:
///
/// ```dart
/// await tester.pump();
/// await tester.pump();
/// ```
///
/// It does this while still allowing nested calls, e.g. so that you can
/// invoke [expect] from inside callbacks.
///
/// You can use this in your own test functions, if you have some asynchronous
/// functions that must be used with "await". Wrap the contents of the function
/// in a call to TestAsyncUtils.guard(), as follows:
///
/// ```dart
/// Future<Null> myTestFunction() => TestAsyncUtils.guard(() async {
///   // ...
/// });
/// ```
class TestAsyncUtils {
  TestAsyncUtils._();
  static const String _className = 'TestAsyncUtils';

  static List<_AsyncScope> _scopeStack = <_AsyncScope>[];

  /// Invokes the given callback in a new async scope. The callback argument is
  /// the asynchronous body of the calling method. The calling method is said to
  /// be "guarded". Nested calls to guarded methods from within the body of this
  /// one are fine, but calls to other guarded methods from outside the body of
  /// this one before this one has finished will throw an exception.
  ///
  /// This method first calls [guardSync].
  static Future<Null> guard(Future<Null> body()) {
    guardSync();
    Zone zone = Zone.current.fork(
      zoneValues: <dynamic, dynamic>{
        _scopeStack: true // so we can recognize this as our own zone
      }
    );
    _AsyncScope scope = new _AsyncScope(StackTrace.current, zone);
    _scopeStack.add(scope);
    Future<Null> result = scope.zone.run(body);
    result = result.whenComplete(() {
      assert(_scopeStack.isNotEmpty);
      assert(_scopeStack.contains(scope));
      bool leaked = false;
      _AsyncScope closedScope;
      StringBuffer message = new StringBuffer();
      while (_scopeStack.isNotEmpty) {
        closedScope = _scopeStack.removeLast();
        if (closedScope == scope)
          break;
        leaked = true;
        message.writeln('Asynchronous call to guarded function leaked. You must use "await" with all Future-returning test APIs.');
        final _StackEntry originalGuarder = _findResponsibleMethod(closedScope.creationStack, 'guard', message);
        if (originalGuarder != null) {
          message.writeln(
            'The test API method "${originalGuarder.methodName}" '
            'from class ${originalGuarder.className} '
            'was called from ${originalGuarder.callerFile} '
            'on line ${originalGuarder.callerLine}, '
            'but never completed before its parent scope closed.'
          );
        }
      }
      if (leaked)
        throw new FlutterError(message.toString().trimRight());
    });
    return result;
  }

  static Zone get _currentScopeZone {
    Zone zone = Zone.current;
    while (zone != null) {
      if (zone[_scopeStack] == true)
        return zone;
      zone = zone.parent;
    }
    return null;
  }

  /// Verifies that there are no guarded methods currently pending (see [guard]).
  ///
  /// If a guarded method is currently pending, and this is not a call nested
  /// from inside that method's body (directly or indirectly), then this method
  /// will throw a detailed exception.
  static void guardSync() {
    if (_scopeStack.isEmpty) {
      // No scopes open, so we must be fine.
      return;
    }
    // Find the current TestAsyncUtils scope zone so we can see if it's the one we expect.
    final Zone zone = _currentScopeZone;
    if (zone == _scopeStack.last.zone) {
      // We're still in the current scope zone. All good.
      return;
    }
    // If we get here, we know we've got a conflict on our hands.
    // We got an async barrier, but the current zone isn't the last scope that
    // we pushed on the stack.
    // Find which scope the conflict happened in, so that we know
    // which stack trace to report the conflict as starting from.
    //
    // For example, if we called an async method A, which ran its body in a
    // guarded block, and in its body it ran an async method B, which ran its
    // body in a guarded block, but we didn't await B, then in A's block we ran
    // an async method C, which ran its body in a guarded block, then we should
    // complain about the call to B then the call to C. BUT. If we called an async
    // method A, which ran its body in a guarded block, and in its body it ran
    // an async method B, which ran its body in a guarded block, but we didn't
    // await A, and then at the top level we called a method D, then we should
    // complain about the call to A then the call to D.
    //
    // In both examples, the scope stack would have two scopes. In the first
    // example, the current zone would be the zone of the _scopeStack[0] scope,
    // and we would want to show _scopeStack[1]'s creationStack. In the second
    // example, the current zone would not be in the _scopeStack, and we would
    // want to show _scopeStack[0]'s creationStack.
    int skipCount = 0;
    _AsyncScope candidateScope = _scopeStack.last;
    _AsyncScope scope;
    do {
      skipCount += 1;
      scope = candidateScope;
      candidateScope = skipCount < _scopeStack.length ? _scopeStack[_scopeStack.length - skipCount - 1] : null;
    } while (candidateScope?.zone != zone);
    assert(scope != null);
    StringBuffer message = new StringBuffer();
    message.writeln('Guarded function conflict. You must use "await" with all Future-returning test APIs.');
    final _StackEntry originalGuarder = _findResponsibleMethod(scope.creationStack, 'guard', message);
    final _StackEntry collidingGuarder = _findResponsibleMethod(StackTrace.current, 'guardSync', message);
    if (originalGuarder != null && collidingGuarder != null) {
      String originalName;
      if (originalGuarder.className == null) {
        originalName = '(${originalGuarder.methodName}) ';
        message.writeln(
          'The guarded "${originalGuarder.methodName}" function '
          'was called from ${originalGuarder.callerFile} '
          'on line ${originalGuarder.callerLine}.'
        );
      } else {
        originalName = '(${originalGuarder.className}.${originalGuarder.methodName}) ';
        message.writeln(
          'The guarded method "${originalGuarder.methodName}" '
          'from class ${originalGuarder.className} '
          'was called from ${originalGuarder.callerFile} '
          'on line ${originalGuarder.callerLine}.'
        );
      }
      final String again = (originalGuarder.callerFile == collidingGuarder.callerFile) &&
                           (originalGuarder.callerLine == collidingGuarder.callerLine) ?
                           'again ' : '';
      String collidingName;
      if ((originalGuarder.className == collidingGuarder.className) &&
          (originalGuarder.methodName == collidingGuarder.methodName)) {
        originalName = '';
        collidingName = '';
        message.writeln(
          'Then, it '
          'was called ${again}from ${collidingGuarder.callerFile} '
          'on line ${collidingGuarder.callerLine}.'
        );
      } else if (collidingGuarder.className == null) {
        collidingName = '(${collidingGuarder.methodName}) ';
        message.writeln(
          'Then, the "${collidingGuarder.methodName}" function '
          'was called ${again}from ${collidingGuarder.callerFile} '
          'on line ${collidingGuarder.callerLine}.'
        );
      } else {
        collidingName = '(${collidingGuarder.className}.${collidingGuarder.methodName}) ';
        message.writeln(
          'Then, the "${collidingGuarder.methodName}" method '
          '${originalGuarder.className == collidingGuarder.className ? "(also from class ${collidingGuarder.className})"
                                                                     : "from class ${collidingGuarder.className}"} '
          'was called ${again}from ${collidingGuarder.callerFile} '
          'on line ${collidingGuarder.callerLine}.'
        );
      }
      message.writeln(
        'The first ${originalGuarder.className == null ? "function" : "method"} $originalName'
        'had not yet finished executing at the time that '
        'the second ${collidingGuarder.className == null ? "function" : "method"} $collidingName'
        'was called. Since both are guarded, and the second was not a nested call inside the first, the '
        'first must complete its execution before the second can be called. Typically, this is achieved by '
        'putting an "await" statement in front of the call to the first.'
      );
      if (collidingGuarder.className == null && collidingGuarder.methodName == 'expect') {
        message.writeln(
          'If you are confident that all test APIs are being called using "await", and '
          'this expect() call is not being invoked at the top level but is itself being '
          'called from some sort of callback registered before the ${originalGuarder.methodName} '
          'method was called, then consider using expectSync() instead.'
        );
      }
      message.writeln(
        '\n'
        'When the first ${originalGuarder.className == null ? "function" : "method"} '
        '$originalName'
        'was called, this was the stack:'
      );
      message.writeln(FlutterError.defaultStackFilter(scope.creationStack.toString().trimRight().split('\n')).join('\n'));
    }
    throw new FlutterError(message.toString().trimRight());
  }

  /// Verifies that there are no guarded methods currently pending (see [guard]).
  ///
  /// This is used at the end of tests to ensure that nothing leaks out of the test.
  static void verifyAllScopesClosed() {
    if (_scopeStack.isNotEmpty) {
      StringBuffer message = new StringBuffer();
      message.writeln('Asynchronous call to guarded function leaked. You must use "await" with all Future-returning test APIs.');
      for (_AsyncScope scope in _scopeStack) {
        final _StackEntry guarder = _findResponsibleMethod(scope.creationStack, 'guard', message);
        if (guarder != null) {
          message.writeln(
            'The guarded method "${guarder.methodName}" '
            '${guarder.className != null ? "from class ${guarder.className} " : ""}'
            'was called from ${guarder.callerFile} '
            'on line ${guarder.callerLine}, '
            'but never completed before its parent scope closed.'
          );
        }
      }
      throw new FlutterError(message.toString().trimRight());
    }
  }

  static _StackEntry _findResponsibleMethod(StackTrace rawStack, String method, StringBuffer errors) {
    assert(method == 'guard' || method == 'guardSync');
    final List<String> stack = rawStack.toString().split('\n');
    assert(stack.last == '');
    stack.removeLast();
    final RegExp getClassPattern = new RegExp(r'^#[0-9]+ +([^. ]+)');
    Match lineMatch;
    int index = -1;
    do { // skip past frames that are from this class
      index += 1;
      assert(index < stack.length);
      lineMatch = getClassPattern.matchAsPrefix(stack[index]);
      assert(lineMatch != null);
      assert(lineMatch.groupCount == 1);
    } while (lineMatch.group(1) == _className);
    // try to parse the stack to find the interesting frame
    if (index < stack.length) {
      final RegExp guardPattern = new RegExp(r'^#[0-9]+ +(?:([^. ]+)\.)?([^. ]+)');
      final Match guardMatch = guardPattern.matchAsPrefix(stack[index]); // find the class that called us
      if (guardMatch != null) {
        assert(guardMatch.groupCount == 2);
        final String guardClass = guardMatch.group(1); // might be null
        final String guardMethod = guardMatch.group(2);
        while (index < stack.length) { // find the last stack frame that called the class that called us
          lineMatch = getClassPattern.matchAsPrefix(stack[index]);
          if (lineMatch != null) {
            assert(lineMatch.groupCount == 1);
            if (lineMatch.group(1) == (guardClass ?? guardMethod)) {
              index += 1;
              continue;
            }
          }
          break;
        }
        if (index < stack.length) {
          final RegExp callerPattern = new RegExp(r'^#[0-9]+ .* \((.+):([0-9]+)(?::[0-9]+)?\)$');
          final Match callerMatch = callerPattern.matchAsPrefix(stack[index]); // extract the caller's info
          if (callerMatch != null) {
            assert(callerMatch.groupCount == 2);
            final String callerFile = callerMatch.group(1);
            final String callerLine = callerMatch.group(2);
            return new _StackEntry(guardClass, guardMethod, callerFile, callerLine);
          } else {
            // One reason you might get here is if the guarding method was called directly from
            // a 'dart:' API, like from the Future/microtask mechanism, because dart: URLs in the
            // stack trace don't have a column number and so don't match the regexp above.
            errors.writeln('(Unable to parse the stack frame of the method that called the method that called $_className.$method(). The stack may be incomplete or bogus.)');
            errors.writeln('${stack[index]}');
          }
        } else {
          errors.writeln('(Unable to find the stack frame of the method that called the method that called $_className.$method(). The stack may be incomplete or bogus.)');
        }
      } else {
        errors.writeln('(Unable to parse the stack frame of the method that called $_className.$method(). The stack may be incomplete or bogus.)');
        errors.writeln('${stack[index]}');
      }
    } else {
      errors.writeln('(Unable to find the method that called $_className.$method(). The stack may be incomplete or bogus.)');
    }
    return null;
  }
}

class _StackEntry {
  const _StackEntry(this.className, this.methodName, this.callerFile, this.callerLine);
  final String className;
  final String methodName;
  final String callerFile;
  final String callerLine;
}
