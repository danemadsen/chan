import 'package:chan/models/flag.dart';
import 'package:chan/sites/4chan.dart';
import 'package:chan/sites/foolfuuka.dart';
import 'package:chan/widgets/refreshable_list.dart';
import 'package:hive/hive.dart';

import 'post_element.dart';

import 'attachment.dart';

part 'post.g.dart';

@HiveType(typeId: 13)
enum PostSpanFormat {
	@HiveField(0)
	Chan4,
	@HiveField(1)
	FoolFuuka
}

@HiveType(typeId: 11)
class Post implements Filterable {
	@HiveField(0)
	final String board;
	@HiveField(1)
	final String text;
	@HiveField(2)
	final String name;
	@HiveField(3)
	final DateTime time;
	@HiveField(4)
	final int threadId;
	@HiveField(5)
	final int id;
	@HiveField(6)
	final Attachment? attachment;
	@HiveField(7)
	final ImageboardFlag? flag;
	@HiveField(8)
	final String? posterId;
	@HiveField(9)
	PostSpanFormat spanFormat;
	PostSpan? _span;
	PostSpan get span {
		if (_span == null) {
			if (spanFormat == PostSpanFormat.Chan4) {
				_span = Site4Chan.makeSpan(text);
			}
			else if (spanFormat == PostSpanFormat.FoolFuuka) {
				_span = FoolFuukaArchive.makeSpan(board, threadId, text);
			}
		}
		return _span!;
	}
	@HiveField(10)
	List<int> replyIds = [];
	Post({
		required this.board,
		required this.text,
		required this.name,
		required this.time,
		required this.threadId,
		required this.id,
		required this.spanFormat,
		this.flag,
		this.attachment,
		this.posterId
	}) {
		this.attachment?.post = this;
	}

	@override
	String toString() {
		return 'Post $id';
	}

	List<String> getSearchableText() {
		return [text];
	}
}