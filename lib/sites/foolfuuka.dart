import 'dart:convert';

import 'package:chan/models/attachment.dart';
import 'package:chan/models/board.dart';
import 'package:chan/models/flag.dart';
import 'package:chan/models/post.dart';
import 'package:chan/models/post_element.dart';
import 'package:chan/models/search.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/sites/4chan.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' show parse;
import 'package:html/dom.dart' as dom;
import 'package:html_unescape/html_unescape_small.dart';

class FoolFuukaArchive implements ImageboardSiteArchive {
	final http.Client client = http.Client();
	List<ImageboardBoard>? _boards;
	final unescape = HtmlUnescape();
	final String baseUrl;
	final String staticUrl;
	final String name;
	ImageboardFlag? _makeFlag(dynamic data) {
		if (data['poster_country'] != null && data['poster_country'].isNotEmpty) {
			return ImageboardFlag(
				name: data['poster_country_name'],
				imageUrl: Uri.https(staticUrl, '/image/country/${data['poster_country'].toLowerCase()}.gif').toString(),
				imageWidth: 16,
				imageHeight: 11
			);
		}
		else if (data['troll_country_name'] != null && data['troll_country_name'].isNotEmpty) {
			return ImageboardFlag(
				name: data['troll_country_name'],
				imageUrl: Uri.https(staticUrl, '/image/country/troll/${data['troll_country_code'].toLowerCase()}.gif').toString(),
				imageWidth: 16,
				imageHeight: 11
			);
		}
	}
	static PostSpan makeSpan(String board, int threadId, String data) {
		final doc = parse(data.replaceAll('<wbr>', ''));
		final List<PostSpan> elements = [];
		int spoilerSpanId = 0;
		for (final node in doc.body!.nodes) {
			if (node is dom.Element) {
				if (node.localName == 'span') {
					if (node.classes.contains('greentext')) {
						final quoteLink = node.querySelector('a.backlink');
						if (quoteLink != null) {
							final parts = quoteLink.attributes['href']!.split('/');
							final linkedBoard = parts[3];
							if (parts.length > 4) {
								final linkType = parts[4];
								final linkedThread = int.parse(parts[5]);
								if (linkType == 'post') {
									elements.add(PostCrossThreadQuoteLinkSpan(linkedBoard, linkedThread, linkedThread));
								}
								else if (linkType == 'thread') {
									final linkedPost = int.parse(parts[6].substring(1));
									if (linkedBoard == board && linkedThread == threadId) {
										elements.add(PostQuoteLinkSpan(linkedPost));
									}
									else {
										elements.add(PostCrossThreadQuoteLinkSpan(linkedBoard, linkedThread, linkedPost));
									}
								}
							}
							else {
								elements.add(PostBoardLink(linkedBoard));
							}
						}
						else {
							elements.add(PostQuoteSpan(makeSpan(board, threadId, node.innerHtml)));
						}
					}
					else if (node.classes.contains('spoiler')) {
						elements.add(PostSpoilerSpan(makeSpan(board, threadId, node.innerHtml), spoilerSpanId++));
					}
					else {
						elements.addAll(Site4Chan.parsePlaintext(node.text));
					}
				}
			}
			else {
				elements.addAll(Site4Chan.parsePlaintext(node.text ?? ''));
			}
		}
		return PostNodeSpan(elements);
	}
	Attachment? _makeAttachment(dynamic data) {
		if (data['media'] != null) {
			final List<String> serverFilenameParts =  data['media']['media_orig'].split('.');
			return Attachment(
				board: data['board']['shortname'],
				id: int.parse(serverFilenameParts.first),
				filename: data['media']['media_filename'],
				ext: '.' + serverFilenameParts.last,
				type: serverFilenameParts.last == 'webm' ? AttachmentType.WEBM : AttachmentType.Image,
				url: Uri.parse(data['media']['media_link']),
				thumbnailUrl: Uri.parse(data['media']['thumb_link']),
				md5: data['media']['safe_media_hash']
			);
		}	
	}
	Post _makePost(dynamic data) {
		final String board = data['board']['shortname'];
		final int threadId = int.parse(data['thread_num']);
		return Post(
			board: board,
			text: data['comment_processed'] ?? '',
			name: data['name'],
			time: DateTime.fromMillisecondsSinceEpoch(data['timestamp'] * 1000),
			id: int.parse(data['num']),
			threadId: threadId,
			attachment: _makeAttachment(data),
			spanFormat: PostSpanFormat.FoolFuuka,
			flag: _makeFlag(data),
			posterId: data['id']
		);
	}
	Future<Post> getPost(String board, int id) async {
		if (!(await getBoards()).any((b) => b.name == board)) {
			throw BoardNotFoundException(board);
		}
		final response = await client.get(Uri.https(baseUrl, '/_/api/chan/post', {
			'board': board,
			'num': id.toString()
		}));
		if (response.statusCode != 200) {
			if (response.statusCode == 404) {
				return Future.error(ThreadNotFoundException(board, id));
			}
			return Future.error(HTTPStatusException(response.statusCode));
		}
		final data = json.decode(response.body);
		return _makePost(data);
	}
	Future<Thread> getThreadContainingPost(String board, int id) async {
		throw Exception('Unimplemented');
	}
	Future<Thread> getThread(String board, int id) async {
		if (!(await getBoards()).any((b) => b.name == board)) {
			throw BoardNotFoundException(board);
		}
		final response = await client.get(Uri.https(baseUrl, '/_/api/chan/thread', {
			'board': board,
			'num': id.toString()
		}));
		if (response.statusCode != 200) {
			if (response.statusCode == 404) {
				return Future.error(ThreadNotFoundException(board, id));
			}
			return Future.error(HTTPStatusException(response.statusCode));
		}
		final data = json.decode(response.body);
		if (data['error'] != null) {
			throw Exception(data['error']);
		}
		final postObjects = [data[id.toString()]['op'], ...data[id.toString()]['posts'].values];
		final posts = postObjects.map<Post>(_makePost).toList();
		final String? title = postObjects.first['title'];
		return Thread(
			board: board,
			isDeleted: false,
			replyCount: posts.length - 1,
			imageCount: posts.where((post) => post.attachment != null).length,
			isArchived: true,
			posts: posts,
			id: id,
			attachment: _makeAttachment(postObjects.first),
			title: (title == null) ? null : unescape.convert(title),
			isSticky: postObjects.first['sticky'] == 1,
			time: posts.first.time,
			flag: _makeFlag(postObjects.first)
		);
	}
	Future<List<Thread>> getCatalog(String board) async {
		throw Exception('Catalog not supported on $name');
	}
	Future<List<ImageboardBoard>> _getBoards() async {
		final response = await client.get(Uri.https(baseUrl, '/_/api/chan/archives'));
		if (response.statusCode != 200) {
			throw HTTPStatusException(response.statusCode);
		}
		final data = json.decode(response.body);
		final Iterable<dynamic> boardData = data['archives'].values;
		return boardData.map((archive) {
			return ImageboardBoard(
				name: archive['shortname'],
				title: archive['name'],
				isWorksafe: !archive['is_nsfw'],
				webmAudioAllowed: false
			);
		}).toList();
	}
	Future<List<ImageboardBoard>> getBoards() async {
		if (_boards == null) {
			_boards = await _getBoards();
		}
		return _boards!;
	}

	Future<ImageboardArchiveSearchResult> search(ImageboardArchiveSearchQuery query, {required int page}) async {
		final knownBoards = await getBoards();
		final unknownBoards = query.boards.where((b) => !knownBoards.any((kb) => kb.name == b));
		if (unknownBoards.isNotEmpty) {
			throw BoardNotFoundException(unknownBoards.first);
		}
		final response = await client.get(Uri.https(baseUrl, '/_/api/chan/search', {
			'text': query.query,
			'page': page.toString(),
			if (query.boards.isNotEmpty) 'boards': query.boards.join('.'),
			if (query.mediaFilter != MediaFilter.None) 'filter': query.mediaFilter == MediaFilter.OnlyWithMedia ? 'text' : 'image',
			if (query.postTypeFilter != PostTypeFilter.None) 'type': query.postTypeFilter == PostTypeFilter.OnlyOPs ? 'op' : 'posts',
			if (query.startDate != null) 'start': '${query.startDate!.year}-${query.startDate!.month}-${query.startDate!.day}',
			if (query.endDate != null) 'end': '${query.endDate!.year}-${query.endDate!.month}-${query.endDate!.day}',
			if (query.md5 != null) 'image': query.md5
		}));
		if (response.statusCode != 200) {
			throw HTTPStatusException(response.statusCode);
		}
		final data = json.decode(response.body);
		return ImageboardArchiveSearchResult(
			posts: (data['0']['posts'] as Iterable<dynamic>).map(_makePost).toList(),
			page: page,
			maxPage: (data['meta']['total_found'] / 25).ceil()
		);
	}

	String getWebUrl(String board, int threadId, [int? postId]) {
		return 'https://$baseUrl/$board/thread/$threadId' + (postId != null ? '#$postId' : '');
	}

	FoolFuukaArchive({
		required this.baseUrl,
		required this.staticUrl,
		required this.name
	});
}