// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:meta/meta.dart';

import '../artifacts.dart';
import '../base/common.dart';
import '../base/file_system.dart';
import '../base/io.dart';
import '../build_info.dart';
import '../globals.dart' as globals;
import '../project.dart';
import '../web/chrome.dart';
import '../web/compile.dart';
import '../web/memory_fs.dart';
import 'flutter_platform.dart' as loader;
import 'flutter_web_platform.dart';
import 'test_wrapper.dart';
import 'watcher.dart';

/// A class that abstracts launching the test process from the test runner.
abstract class FlutterTestRunner {
  const factory FlutterTestRunner() = _FlutterTestRunnerImpl;

  /// Runs tests using package:test and the Flutter engine.
  Future<int> runTests(
    TestWrapper testWrapper,
    List<String> testFiles, {
    Directory workDir,
    List<String> names = const <String>[],
    List<String> plainNames = const <String>[],
    String tags,
    String excludeTags,
    bool enableObservatory = false,
    bool startPaused = false,
    bool disableServiceAuthCodes = false,
    bool disableDds = false,
    bool ipv6 = false,
    bool machine = false,
    String precompiledDillPath,
    Map<String, String> precompiledDillFiles,
    bool updateGoldens = false,
    TestWatcher watcher,
    @required int concurrency,
    bool buildTestAssets = false,
    FlutterProject flutterProject,
    String icudtlPath,
    Directory coverageDirectory,
    bool web = false,
    String randomSeed,
    bool nullAssertions = false,
    @required BuildInfo buildInfo,
    String reporter,
    String timeout,
  });
}

class _FlutterTestRunnerImpl implements FlutterTestRunner {
  const _FlutterTestRunnerImpl();

  @override
  Future<int> runTests(
    TestWrapper testWrapper,
    List<String> testFiles, {
    Directory workDir,
    List<String> names = const <String>[],
    List<String> plainNames = const <String>[],
    String tags,
    String excludeTags,
    bool enableObservatory = false,
    bool startPaused = false,
    bool disableServiceAuthCodes = false,
    bool disableDds = false,
    bool ipv6 = false,
    bool machine = false,
    String precompiledDillPath,
    Map<String, String> precompiledDillFiles,
    bool updateGoldens = false,
    TestWatcher watcher,
    @required int concurrency,
    bool buildTestAssets = false,
    FlutterProject flutterProject,
    String icudtlPath,
    Directory coverageDirectory,
    bool web = false,
    String randomSeed,
    bool nullAssertions = false,
    @required BuildInfo buildInfo,
    String reporter,
    String timeout,
  }) async {
    // Configure package:test to use the Flutter engine for child processes.
    final String shellPath = globals.artifacts.getArtifactPath(Artifact.flutterTester);

    // Compute the command-line arguments for package:test.
    final List<String> testArgs = <String>[
      if (!globals.terminal.supportsColor)
        '--no-color',
      if (startPaused)
        '--pause-after-load',
      if (machine)
        ...<String>['-r', 'json']
      else
        ...<String>['-r', reporter ?? 'compact'],
      if (timeout != null)
        ...<String>['--timeout', timeout],
      '--concurrency=$concurrency',
      for (final String name in names)
        ...<String>['--name', name],
      for (final String plainName in plainNames)
        ...<String>['--plain-name', plainName],
      if (randomSeed != null)
        '--test-randomize-ordering-seed=$randomSeed',
      if (tags != null)
        ...<String>['--tags', tags],
      if (excludeTags != null)
        ...<String>['--exclude-tags', excludeTags],
    ];
    if (web) {
      final String tempBuildDir = globals.fs.systemTempDirectory
        .createTempSync('flutter_test.')
        .absolute
        .uri
        .toFilePath();
      final WebMemoryFS result = await webCompilationProxy.initialize(
        projectDirectory: flutterProject.directory,
        testOutputDir: tempBuildDir,
        testFiles: testFiles,
        buildInfo: buildInfo,
      );
      if (result == null) {
        throwToolExit('Failed to compile tests');
      }
      testArgs
        ..add('--platform=chrome')
        ..add('--precompiled=$tempBuildDir')
        ..add('--')
        ..addAll(testFiles);
      testWrapper.registerPlatformPlugin(
        <Runtime>[Runtime.chrome],
        () {
          // TODO(jonahwilliams): refactor this into a factory that handles
          // providing dependencies.
          return FlutterWebPlatform.start(
            flutterProject.directory.path,
            updateGoldens: updateGoldens,
            shellPath: shellPath,
            flutterProject: flutterProject,
            pauseAfterLoad: startPaused,
            nullAssertions: nullAssertions,
            buildInfo: buildInfo,
            webMemoryFS: result,
            logger: globals.logger,
            fileSystem: globals.fs,
            artifacts: globals.artifacts,
            chromiumLauncher: ChromiumLauncher(
              fileSystem: globals.fs,
              platform: globals.platform,
              processManager: globals.processManager,
              operatingSystemUtils: globals.os,
              browserFinder: findChromeExecutable,
              logger: globals.logger,
            ),
          );
        },
      );
      await testWrapper.main(testArgs);
      return exitCode;
    }

    testArgs
      ..add('--')
      ..addAll(testFiles);

    final InternetAddressType serverType =
        ipv6 ? InternetAddressType.IPv6 : InternetAddressType.IPv4;

    final loader.FlutterPlatform platform = loader.installHook(
      testWrapper: testWrapper,
      shellPath: shellPath,
      watcher: watcher,
      enableObservatory: enableObservatory,
      machine: machine,
      startPaused: startPaused,
      disableServiceAuthCodes: disableServiceAuthCodes,
      disableDds: disableDds,
      serverType: serverType,
      precompiledDillPath: precompiledDillPath,
      precompiledDillFiles: precompiledDillFiles,
      updateGoldens: updateGoldens,
      buildTestAssets: buildTestAssets,
      projectRootDirectory: globals.fs.currentDirectory.uri,
      flutterProject: flutterProject,
      icudtlPath: icudtlPath,
      nullAssertions: nullAssertions,
      buildInfo: buildInfo,
    );

    // Call package:test's main method in the appropriate directory.
    final Directory saved = globals.fs.currentDirectory;
    try {
      if (workDir != null) {
        globals.printTrace('switching to directory $workDir to run tests');
        globals.fs.currentDirectory = workDir;
      }

      globals.printTrace('running test package with arguments: $testArgs');
      await testWrapper.main(testArgs);

      // test.main() sets dart:io's exitCode global.
      globals.printTrace('test package returned with exit code $exitCode');

      return exitCode;
    } finally {
      globals.fs.currentDirectory = saved.path;
      await platform.close();
    }
  }
}
