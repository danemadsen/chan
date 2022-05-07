import 'package:chan/models/flag.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/services/filtering.dart';
import 'package:chan/sites/4chan.dart';
import 'package:chan/sites/foolfuuka.dart';
import 'package:chan/sites/fuuka.dart';
import 'package:chan/sites/lainchan.dart';
import 'package:hive/hive.dart';

import '../widgets/post_spans.dart';

import 'attachment.dart';

part 'post.g.dart';

@HiveType(typeId: 13)
enum PostSpanFormat {
	@HiveField(0)
	chan4,
	@HiveField(1)
	foolFuuka,
	@HiveField(2)
	lainchan,
	@HiveField(3)
	fuuka
}

@HiveType(typeId: 11)
class Post implements Filterable {
	@override
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
	@override
	@HiveField(5)
	final int id;
	@HiveField(6)
	Attachment? attachment;
	@HiveField(7)
	final ImageboardFlag? flag;
	@HiveField(8)
	final String? posterId;
	@HiveField(9)
	PostSpanFormat spanFormat;
	PostNodeSpan? _span;
	@HiveField(12)
	Map<String, int>? foolfuukaLinkedPostThreadIds;
	PostNodeSpan get span {
		if (_span == null) {
			if (spanFormat == PostSpanFormat.chan4) {
				_span = Site4Chan.makeSpan(board, threadId, text);
			}
			else if (spanFormat == PostSpanFormat.foolFuuka) {
				_span = FoolFuukaArchive.makeSpan(board, threadId, foolfuukaLinkedPostThreadIds ?? {}, text);
			}
			else if (spanFormat == PostSpanFormat.lainchan) {
				_span = SiteLainchan.makeSpan(board, threadId, text);
			}
			else if (spanFormat == PostSpanFormat.fuuka) {
				_span = FuukaArchive.makeSpan(board, threadId, foolfuukaLinkedPostThreadIds ?? {}, text);
			}
		}
		return _span!;
	}
	@HiveField(10)
	List<int> replyIds = [];
	@HiveField(11, defaultValue: false)
	bool attachmentDeleted;
	@HiveField(13)
	String? trip;
	@HiveField(14)
	int? passSinceYear;
	Post({
		required this.board,
		required this.text,
		required this.name,
		required this.time,
		this.trip,
		required this.threadId,
		required this.id,
		required this.spanFormat,
		this.flag,
		this.attachment,
		this.attachmentDeleted = false,
		this.posterId,
		this.foolfuukaLinkedPostThreadIds,
		this.passSinceYear
	});

	@override
	String toString() {
		return 'Post $id';
	}

	@override
	String? getFilterFieldText(String fieldName) {
		switch (fieldName) {
			case 'name':
				return name;
			case 'filename':
				return attachment?.filename;
			case 'text':
				return span.buildText();
			case 'postID':
				return id.toString();
			case 'posterID':
				return posterId;
			case 'flag':
				return flag?.name;
			case 'md5':
				return attachment?.md5;
			default:
				return null;
		}
	}
	@override
	bool get hasFile => attachment != null;
	@override
	bool get isThread => false;
	@override
	List<int> get repliedToIds => span.referencedPostIds(board);

	ThreadIdentifier get threadIdentifier => ThreadIdentifier(board, threadId);

	String get globalId => '${board}_${threadId}_$id';

	@override
	bool operator ==(dynamic other) => other is Post && other.board == board && other.id == id;

	@override
	int get hashCode => Object.hash(board, id);
}