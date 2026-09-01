import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/services/platform_service.dart';
import 'package:mod_manager_flutter/services/platform_service_linux.dart';
import 'package:mod_manager_flutter/utils/process_probe.dart';

/// A [ProcessProbe] that answers from a script and records what was asked.
///
/// The recording is half the point: the assertions that matter most here are
/// about a command that must **not** have run.
class _ScriptedProbe extends ProcessProbe {
  _ScriptedProbe(this.answer);

  final ProbeResult? Function(String executable, List<String> arguments) answer;
  final List<String> calls = [];

  @override
  Future<ProbeResult?> run(
    String executable,
    List<String> arguments, {
    Duration? timeout,
  }) async {
    calls.add([executable, ...arguments].join(' '));
    return answer(executable, arguments);
  }

  bool ran(String command) => calls.any((call) => call.startsWith(command));
}

ProbeResult _ok([String stdout = '']) =>
    ProbeResult(exitCode: 0, stdout: stdout, stderr: '');
ProbeResult _exits(int code) =>
    ProbeResult(exitCode: code, stdout: '', stderr: '');

void main() {
  /// The window id the scripted searches hand back.
  const window = '79691777';

  group('F10 is only sent to a window that was found', () {
    test('a missing xdotool is reported, and no key is pressed', () async {
      final probe = _ScriptedProbe((executable, arguments) {
        if (executable == 'which') return _exits(1);
        fail('nothing else may run once the tool is known to be missing');
      });

      final result = await LinuxPlatformService(probe: probe).sendF10ToGame();

      expect(result.outcome, F10Outcome.toolMissing);
      expect(result.tool, 'xdotool');
      expect(result.sent, isFalse);
      expect(probe.ran('xdotool key'), isFalse);
    });

    test('no game window means no key press at all', () async {
      // The regression this exists for: the previous implementation answered a
      // failed search with a blind `xdotool key F10` — pressing F10 into
      // whatever had focus, which is the mod manager — and returned success.
      final probe = _ScriptedProbe((executable, arguments) {
        if (executable == 'which') return _ok('/usr/bin/xdotool');
        if (arguments.first == 'search') return _exits(1);
        fail('no window was found, so nothing may be pressed');
      });

      final result = await LinuxPlatformService(probe: probe).sendF10ToGame();

      expect(result.outcome, F10Outcome.gameNotFound);
      expect(result.sent, isFalse);
      expect(probe.ran('xdotool key'), isFalse);
    });

    test('a window that will not come forward is a failure, not a press',
        () async {
      final probe = _ScriptedProbe((executable, arguments) {
        if (executable == 'which') return _ok('/usr/bin/xdotool');
        return switch (arguments.first) {
          'search' => _ok(window),
          'windowactivate' => _ok(),
          // A compositor refusing the activation: something else stays focused.
          'getactivewindow' => _ok('12345'),
          _ => fail('the game never got focus, so nothing may be pressed'),
        };
      });

      final result = await LinuxPlatformService(probe: probe).sendF10ToGame();

      expect(result.outcome, F10Outcome.sendFailed);
      expect(result.sent, isFalse);
      expect(probe.ran('xdotool key'), isFalse);
    });

    test('a focused game window is pressed, and not through --window',
        () async {
      final probe = _ScriptedProbe((executable, arguments) {
        if (executable == 'which') return _ok('/usr/bin/xdotool');
        return switch (arguments.first) {
          'search' => _ok(window),
          'windowactivate' => _ok(),
          'getactivewindow' => _ok(window),
          'key' => _ok(),
          _ => null,
        };
      });

      final result = await LinuxPlatformService(probe: probe).sendF10ToGame();

      expect(result.outcome, F10Outcome.sent);
      expect(result.tool, 'xdotool');
      expect(result.sent, isTrue);
      // `key --window <id>` would be an XSendEvent, which Wine does not fold
      // into the keyboard state 3DMigoto polls — so it must be the plain,
      // XTEST form that runs.
      expect(probe.calls, contains('xdotool key F10'));
      expect(probe.ran('xdotool key --window'), isFalse);
      // And the window has to have been brought forward before it.
      expect(
        probe.calls.indexOf('xdotool windowactivate $window'),
        lessThan(probe.calls.indexOf('xdotool key F10')),
      );
    });

    test('a key press that the tool rejects is reported as a failure',
        () async {
      final probe = _ScriptedProbe((executable, arguments) {
        if (executable == 'which') return _ok('/usr/bin/xdotool');
        return switch (arguments.first) {
          'search' => _ok(window),
          'windowactivate' => _ok(),
          'getactivewindow' => _ok(window),
          'key' => _exits(1),
          _ => null,
        };
      });

      final result = await LinuxPlatformService(probe: probe).sendF10ToGame();

      expect(result.outcome, F10Outcome.sendFailed);
      expect(result.sent, isFalse);
    });

    test('the window search takes the first id when several match', () async {
      final probe = _ScriptedProbe((executable, arguments) {
        if (executable == 'which') return _ok('/usr/bin/xdotool');
        return switch (arguments.first) {
          'search' => _ok('$window\n88888888\n'),
          'windowactivate' => _ok(),
          'getactivewindow' => _ok(window),
          'key' => _ok(),
          _ => null,
        };
      });

      final result = await LinuxPlatformService(probe: probe).sendF10ToGame();

      expect(result.sent, isTrue);
      expect(probe.calls, contains('xdotool windowactivate $window'));
    });

    test('a search that exits 0 with nothing on stdout is not a window',
        () async {
      final probe = _ScriptedProbe((executable, arguments) {
        if (executable == 'which') return _ok('/usr/bin/xdotool');
        if (arguments.first == 'search') return _ok('   \n');
        fail('an empty result is not a window to press keys into');
      });

      final result = await LinuxPlatformService(probe: probe).sendF10ToGame();

      expect(result.outcome, F10Outcome.gameNotFound);
    });
  });

  group('the dependency check', () {
    test('asks for xdotool, whichever display server is running', () async {
      // The tool has to find the game's window before it can press anything
      // into it, and `ydotool` cannot see windows at all — so asking for
      // `ydotool` on Wayland sent people to install the wrong package.
      final probe = _ScriptedProbe((executable, arguments) => _ok('/usr/bin/x'));

      await LinuxPlatformService(probe: probe).checkDependencies();

      expect(probe.calls, ['which xdotool']);
    });

    test('reports a missing tool as false', () async {
      final probe = _ScriptedProbe((executable, arguments) => _exits(1));

      final present = await LinuxPlatformService(probe: probe).checkDependencies();

      expect(present, isFalse);
    });
  });
}
