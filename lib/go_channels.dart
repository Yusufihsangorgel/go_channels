/// Go-style concurrency for Dart: typed [Channel]s, a faithful [select], and
/// structured task scopes with cancellation.
library;

export 'src/channel.dart' show Channel, ChannelClosedError, SelectCases, select;
export 'src/scope.dart'
    show
        CancelToken,
        CancelledException,
        TaskScope,
        withTaskScope,
        waitAll,
        withTimeout;
