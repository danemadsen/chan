import 'package:chan/widgets/attachment_thumbnail.dart';
import 'package:flutter/cupertino.dart';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:chan/models/thread.dart';

class ThreadRow extends StatelessWidget {
	final Thread thread;
	final bool isSelected;
	const ThreadRow({
		required this.thread,
		required this.isSelected,
	});
	@override
	Widget build(BuildContext context) {
		return Container(
			decoration: BoxDecoration(
				color: isSelected ? ((MediaQuery.of(context).platformBrightness == Brightness.light) ? Colors.grey.shade400 : Colors.grey.shade800) : null
			),
			child: Row(
				crossAxisAlignment: CrossAxisAlignment.start,
				mainAxisSize: MainAxisSize.max,
				children: [
					if (thread.attachment != null)
						AttachmentThumbnail(
							attachment: thread.attachment!
						),
					Expanded(child: Container(
						padding: EdgeInsets.all(8),
						child: Column(
							crossAxisAlignment: CrossAxisAlignment.start,
							mainAxisAlignment: MainAxisAlignment.start,
							children: [
								if (thread.title != null) Text(thread.title!, style: TextStyle(fontWeight: FontWeight.bold)),
								Provider.value(
									value: thread.posts[0],
									child: Builder(
										builder: (ctx) => Text.rich(thread.posts[0].span.build(ctx))
									)
								)
							]
						)
					))
				]
			)
		);
	}
}