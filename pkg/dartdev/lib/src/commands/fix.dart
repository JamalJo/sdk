// Copyright (c) 2020, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io' as io;

import 'package:analysis_server_client/protocol.dart' hide AnalysisError;
import 'package:intl/intl.dart';
import 'package:path/path.dart' as path;

import '../analysis_server.dart';
import '../core.dart';
import '../sdk.dart';
import '../utils.dart';

class FixCommand extends DartdevCommand {
  static const String cmdName = 'fix';

  static final NumberFormat _numberFormat = NumberFormat.decimalPattern();

  static const String cmdDescription =
      '''Apply automated fixes to Dart source code.

This tool looks for and fixes analysis issues that have associated automated fixes.

To use the tool, run either ['dart fix --dry-run'] for a preview of the proposed changes for a project, or ['dart fix --apply'] to apply the changes.''';

  /// The maximum number of times that fixes will be requested from the server.
  static const maxPasses = 4;

  /// A map from the absolute path of a file to the updated content of the file.
  final Map<String, String> fileContentCache = {};

  FixCommand({bool verbose = false}) : super(cmdName, cmdDescription, verbose) {
    argParser.addFlag('dry-run',
        abbr: 'n',
        defaultsTo: false,
        negatable: false,
        help: 'Preview the proposed changes but make no changes.');
    argParser.addFlag(
      'apply',
      defaultsTo: false,
      negatable: false,
      help: 'Apply the proposed changes.',
    );
    argParser.addFlag(
      'compare-to-golden',
      defaultsTo: false,
      negatable: false,
      help:
          'Compare the result of applying fixes to a golden file for testing.',
      hide: !verbose,
    );
  }

  @override
  String get description {
    if (log != null && log.ansi.useAnsi) {
      return cmdDescription
          .replaceAll('[', log.ansi.bold)
          .replaceAll(']', log.ansi.none);
    } else {
      return cmdDescription.replaceAll('[', '').replaceAll(']', '');
    }
  }

  @override
  FutureOr<int> run() async {
    var dryRun = argResults['dry-run'];
    var inTestMode = argResults['compare-to-golden'];
    var apply = argResults['apply'];
    if (!apply && !dryRun && !inTestMode) {
      printUsage();
      return 0;
    }

    var arguments = argResults.rest;
    var argumentCount = arguments.length;
    if (argumentCount > 1) {
      usageException('Only one file or directory is expected.');
    }

    var dir =
        argumentCount == 0 ? io.Directory.current : io.Directory(arguments[0]);
    if (!dir.existsSync()) {
      usageException("Directory doesn't exist: ${dir.path}");
    }
    dir = io.Directory(path.canonicalize(path.normalize(dir.absolute.path)));
    var dirPath = dir.path;

    var modeText = dryRun ? ' (dry run)' : '';

    final projectName = path.basename(dirPath);
    var computeFixesProgress = log.progress(
        'Computing fixes in ${log.ansi.emphasized(projectName)}$modeText');

    var server = AnalysisServer(
      null,
      io.Directory(sdk.sdkPath),
      [dir],
      commandName: 'fix',
      argResults: argResults,
    );

    await server.start();

    server.onExit.then((int exitCode) {
      if (computeFixesProgress != null && exitCode != 0) {
        computeFixesProgress?.cancel();
        computeFixesProgress = null;
        io.exitCode = exitCode;
      }
    });

    Future<Map<String, BulkFix>> _applyAllEdits() async {
      var detailsMap = <String, BulkFix>{};
      List<SourceFileEdit> edits;
      var pass = 0;
      do {
        var fixes = await server.requestBulkFixes(dirPath, inTestMode);
        _mergeDetails(detailsMap, fixes.details);
        edits = fixes.edits;
        _applyEdits(server, edits);
        pass++;
        // TODO(brianwilkerson) Be more intelligent about detecting infinite
        //  loops so that we can increase [maxPasses].
      } while (pass < maxPasses && edits.isNotEmpty);
      return detailsMap;
    }

    var detailsMap = await _applyAllEdits();
    await server.shutdown();

    if (computeFixesProgress != null) {
      computeFixesProgress.finish(showTiming: true);
      computeFixesProgress = null;
    }

    if (inTestMode) {
      var result = _compareFixesInDirectory(dir);
      log.stdout('Passed: ${result.passCount}, Failed: ${result.failCount}');
      return result.failCount > 0 ? 1 : 0;
    } else if (detailsMap.isEmpty) {
      log.stdout('Nothing to fix!');
    } else {
      var fileCount = detailsMap.length;
      var fixCount = detailsMap.values
          .expand((detail) => detail.fixes)
          .fold(0, (previousValue, fixes) => previousValue + fixes.occurrences);

      if (dryRun) {
        log.stdout('');
        log.stdout('${_format(fixCount)} proposed ${_pluralFix(fixCount)} '
            'in ${_format(fileCount)} ${pluralize("file", fileCount)}.');
        _printDetails(detailsMap, dir);
      } else {
        var applyFixesProgress = log.progress('Applying fixes');
        _writeFiles();
        applyFixesProgress.finish(showTiming: true);
        _printDetails(detailsMap, dir);
        log.stdout('${_format(fixCount)} ${_pluralFix(fixCount)} made in '
            '${_format(fileCount)} ${pluralize("file", fileCount)}.');
      }
    }

    return 0;
  }

  void _applyEdits(AnalysisServer server, List<SourceFileEdit> edits) {
    var overlays = <String, AddContentOverlay>{};
    for (var edit in edits) {
      var filePath = edit.file;
      var content = fileContentCache.putIfAbsent(filePath, () {
        var file = io.File(filePath);
        return file.existsSync() ? file.readAsStringSync() : '';
      });
      var newContent = SourceEdit.applySequence(content, edit.edits);
      fileContentCache[filePath] = newContent;
      overlays[filePath] = AddContentOverlay(newContent);
    }
    server.updateContent(overlays);
  }

  /// Return `true` if any of the fixes fail to create the same content as is
  /// found in the golden file.
  _TestResult _compareFixesInDirectory(io.Directory directory) {
    var result = _TestResult();
    //
    // Gather the files of interest in this directory and process
    // subdirectories.
    //
    var dartFiles = <io.File>[];
    var expectFileMap = <String, io.File>{};
    for (var child in directory.listSync()) {
      if (child is io.Directory) {
        var childResult = _compareFixesInDirectory(child);
        result.passCount += childResult.passCount;
        result.failCount += childResult.failCount;
      } else if (child is io.File) {
        var name = child.name;
        if (name.endsWith('.dart')) {
          dartFiles.add(child);
        } else if (name.endsWith('.expect')) {
          expectFileMap[child.path] = child;
        }
      }
    }
    for (var originalFile in dartFiles) {
      var filePath = originalFile.path;
      var baseName = path.basename(filePath);
      var expectFileName = baseName + '.expect';
      var expectFilePath = path.join(path.dirname(filePath), expectFileName);
      var expectFile = expectFileMap.remove(expectFilePath);
      if (expectFile == null) {
        result.failCount++;
        log.stdout(
            'No corresponding expect file for the Dart file at "$filePath".');
        continue;
      }
      try {
        var expectedCode = expectFile.readAsStringSync();
        var actualCode =
            fileContentCache[filePath] ?? originalFile.readAsStringSync();
        // Use a whitespace insensitive comparison.
        if (_compressWhitespace(actualCode) !=
            _compressWhitespace(expectedCode)) {
          result.failCount++;
          // TODO(brianwilkerson) Do a better job of displaying the differences.
          //  It's very hard to see the diff with large files.
          _reportFailure(filePath, actualCode, expectedCode);
        } else {
          result.passCount++;
        }
      } on io.FileSystemException {
        result.failCount++;
        log.stdout('Failed to process "$filePath".');
        log.stdout(
            '  Ensure that the file and its expect file are both readable.');
      }
    }
    //
    // Report any `.expect` files that have no corresponding `.dart` file.
    //
    for (var unmatchedExpectPath in expectFileMap.keys) {
      result.failCount++;
      log.stdout(
          'No corresponding Dart file for the expect file at "$unmatchedExpectPath".');
    }
    return result;
  }

  /// Compress sequences of whitespace characters into a single space.
  String _compressWhitespace(String code) =>
      code.replaceAll(RegExp(r'\s+'), ' ');

  /// Merge the fixes from the current round's [details] into the [detailsMap].
  void _mergeDetails(Map<String, BulkFix> detailsMap, List<BulkFix> details) {
    for (var detail in details) {
      var previousDetail = detailsMap[detail.path];
      if (previousDetail != null) {
        _mergeFixCounts(previousDetail.fixes, detail.fixes);
      } else {
        detailsMap[detail.path] = detail;
      }
    }
  }

  void _mergeFixCounts(
      List<BulkFixDetail> oldFixes, List<BulkFixDetail> newFixes) {
    var originalOldLength = oldFixes.length;
    newFixLoop:
    for (var newFix in newFixes) {
      var newCode = newFix.code;
      // Iterate over the original content of the list, not any of the newly
      // added fixes, because the newly added fixes can't be a match.
      for (var i = 0; i < originalOldLength; i++) {
        var oldFix = oldFixes[i];
        if (oldFix.code == newCode) {
          oldFix.occurrences += newFix.occurrences;
          continue newFixLoop;
        }
      }
      oldFixes.add(newFix);
    }
  }

  String _pluralFix(int count) => count == 1 ? 'fix' : 'fixes';

  void _printDetails(Map<String, BulkFix> detailsMap, io.Directory workingDir) {
    String relative(String absolutePath) {
      return path.relative(absolutePath, from: workingDir.path);
    }

    log.stdout('');

    final bullet = log.ansi.bullet;

    var modifiedFilePaths = detailsMap.keys.toList();
    modifiedFilePaths
        .sort((first, second) => relative(first).compareTo(relative(second)));
    for (var filePath in modifiedFilePaths) {
      var detail = detailsMap[filePath];
      log.stdout(relative(detail.path));
      final fixes = detail.fixes.toList();
      fixes.sort((a, b) => a.code.compareTo(b.code));
      for (var fix in fixes) {
        log.stdout('  ${fix.code} $bullet '
            '${_format(fix.occurrences)} ${_pluralFix(fix.occurrences)}');
      }
      log.stdout('');
    }
  }

  /// Report that the [actualCode] produced by applying fixes to the content of
  /// [filePath] did not match the [expectedCode].
  void _reportFailure(String filePath, String actualCode, String expectedCode) {
    log.stdout('Failed when applying fixes to $filePath');
    log.stdout('Expected:');
    log.stdout(expectedCode);
    log.stdout('');
    log.stdout('Actual:');
    log.stdout(actualCode);
  }

  /// Write the modified contents of files in the [fileContentCache] to disk.
  void _writeFiles() {
    for (var entry in fileContentCache.entries) {
      var file = io.File(entry.key);
      file.writeAsStringSync(entry.value);
    }
  }

  static String _format(int value) => _numberFormat.format(value);
}

/// The result of running tests in a given directory.
class _TestResult {
  /// The number of tests that passed.
  int passCount = 0;

  /// The number of tests that failed.
  int failCount = 0;

  /// Initialize a newly created result object.
  _TestResult();
}
