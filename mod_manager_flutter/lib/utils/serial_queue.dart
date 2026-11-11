/// Async actions run one after another, each starting once the one before it has ended, however it ended.
///
/// Each [run] returns its own action's result or error; an action that fails does not stop the ones queued after it.
class SerialQueue {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }
}
