import 'package:chan/providers/provider.dart';
import 'package:flutter/material.dart';

import 'package:chan/models/post.dart';
import 'package:chan/models/thread.dart';

import 'package:chan/widgets/post_list.dart';
import 'package:chan/widgets/data_stream_provider.dart';

class ThreadPage extends StatefulWidget {
	final Thread thread;
	final ImageboardProvider provider;
  final bool isDesktop;
	final GlobalKey<RefreshIndicatorState> refreshKey = GlobalKey();

	ThreadPage({
		@required this.thread,
		@required this.provider,
    @required this.isDesktop
	});

  @override
  createState() => _ThreadPageState();
}

class _ThreadPageState extends State<ThreadPage> {
	@override
	Widget build(BuildContext context) {
		return DataProvider<Thread>(
      id: widget.provider.name + '/' + widget.thread.board + '/' + widget.thread.id.toString(),
			updater: () => widget.provider.getThread(widget.thread.board, widget.thread.id),
			initialValue: widget.thread,
      onError: (error) {
        Scaffold.of(context).showSnackBar(SnackBar(
          content: Text("Error: " + error.toString())
        ));
      },
      placeholder: (context, dynamic thread) {
        return Scaffold(
          appBar: AppBar(title: Text(thread.id.toString())),
          body: Center(
            child: CircularProgressIndicator()
          )
        );
      },
			builder: (BuildContext context, dynamic thread, Future<void> Function() requestUpdate) {
				return Scaffold(
					appBar: AppBar(title: Text(thread.id.toString())),
					body: RefreshIndicator(
						key: widget.refreshKey,
						onRefresh: requestUpdate,
						child: ListView(
							children: [
								PostList(
                  list: thread.posts,
                  isDesktop: widget.isDesktop
                ),
								RaisedButton(
									onPressed: () {
										widget.refreshKey.currentState.show();
									},
									child: const Text('Refresh')
								)
							]
						)
					)
				);
			}
		);
	}
}