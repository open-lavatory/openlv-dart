import 'dart:io';

const platforms = {'android', 'ios', 'linux', 'macos', 'windows'};

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.any((arg) => !platforms.contains(arg))) {
    stderr.writeln(
      'Usage: dart tool/setup.dart <android|ios|linux|macos|windows> [...]',
    );
    exitCode = 64;
    return;
  }

  final example = File.fromUri(Platform.script).parent.parent;
  final flutter = Platform.isWindows ? 'flutter.bat' : 'flutter';
  final process = await Process.start(
    flutter,
    [
      'create',
      '--no-pub',
      '--org',
      'sh.openlv',
      '--project-name',
      'openlv_example',
      '--platforms',
      args.toSet().join(','),
      '.',
    ],
    workingDirectory: example.path,
    mode: ProcessStartMode.inheritStdio,
  );
  final result = await process.exitCode;
  if (result != 0) {
    exitCode = result;
    return;
  }

  if (args.contains('android')) {
    final manifest = File(
      '${example.path}/android/app/src/main/AndroidManifest.xml',
    );
    final content = manifest.readAsStringSync();
    if (!content.contains('android.permission.INTERNET')) {
      if (!content.contains('<application')) {
        throw StateError('Cannot find application in ${manifest.path}');
      }
      manifest.writeAsStringSync(
        content.replaceFirst(
          '<application',
          '<uses-permission android:name="android.permission.INTERNET"/>\n    <application',
        ),
      );
    }
  }

  if (args.contains('macos')) {
    for (final name in ['DebugProfile', 'Release']) {
      final file = File('${example.path}/macos/Runner/$name.entitlements');
      final content = file.readAsStringSync();
      const key = '<key>com.apple.security.network.client</key>';
      final existing = RegExp('$key\\s*<(true|false)\\s*/>');
      if (existing.hasMatch(content)) {
        file.writeAsStringSync(
          content.replaceFirst(existing, '$key\n\t<true/>'),
        );
      } else {
        if (content.contains(key) || !content.contains('</dict>')) {
          throw StateError('Cannot update network entitlement in ${file.path}');
        }
        file.writeAsStringSync(
          content.replaceFirst('</dict>', '\t$key\n\t<true/>\n</dict>'),
        );
      }
    }
  }
}
