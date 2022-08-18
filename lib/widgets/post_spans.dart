import 'dart:isolate';

import 'package:chan/models/post.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/pages/board.dart';
import 'package:chan/pages/gallery.dart';
import 'package:chan/pages/posts.dart';
import 'package:chan/pages/thread.dart';
import 'package:chan/services/embed.dart';
import 'package:chan/services/filtering.dart';
import 'package:chan/services/imageboard.dart';
import 'package:chan/services/persistence.dart';
import 'package:chan/services/settings.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:chan/widgets/cupertino_page_route.dart';
import 'package:chan/widgets/hover_popup.dart';
import 'package:chan/widgets/imageboard_icon.dart';
import 'package:chan/widgets/imageboard_scope.dart';
import 'package:chan/widgets/post_row.dart';
import 'package:chan/util.dart';
import 'package:chan/widgets/reply_box.dart';
import 'package:chan/widgets/tex.dart';
import 'package:chan/widgets/thread_spans.dart';
import 'package:chan/widgets/weak_navigator.dart';
import 'package:extended_image/extended_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:chan/widgets/util.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:highlight/highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark-reasonable.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:tuple/tuple.dart';

class PostSpanRenderOptions {
	final TapGestureRecognizer? recognizer;
	final bool overrideRecognizer;
	final Color? overrideTextColor;
	final bool showCrossThreadLabel;
	final bool addExpandingPosts;
	final TextStyle baseTextStyle;
	final bool showRawSource;
	final bool avoidBuggyClippers;
	final PointerEnterEventListener? onEnter;
	final PointerExitEventListener? onExit;
	final bool ownLine;
	final bool shrinkWrap;
	final int maxLines;
	final String? highlightString;
	PostSpanRenderOptions({
		this.recognizer,
		this.overrideRecognizer = false,
		this.overrideTextColor,
		this.showCrossThreadLabel = true,
		this.addExpandingPosts = true,
		this.baseTextStyle = const TextStyle(),
		this.showRawSource = false,
		this.avoidBuggyClippers = false,
		this.onEnter,
		this.onExit,
		this.ownLine = false,
		this.shrinkWrap = false,
		this.maxLines = 999999,
		this.highlightString
	});
	TapGestureRecognizer? get overridingRecognizer => overrideRecognizer ? recognizer : null;

	PostSpanRenderOptions copyWith({
		bool? ownLine,
		TextStyle? baseTextStyle,
		bool? showCrossThreadLabel,
		bool? shrinkWrap,
		bool? addExpandingPosts,
		bool? avoidBuggyClippers,
		int? maxLines
	}) => PostSpanRenderOptions(
		recognizer: recognizer,
		overrideRecognizer: overrideRecognizer,
		overrideTextColor: overrideTextColor,
		showCrossThreadLabel: showCrossThreadLabel ?? this.showCrossThreadLabel,
		addExpandingPosts: addExpandingPosts ?? this.addExpandingPosts,
		baseTextStyle: baseTextStyle ?? this.baseTextStyle,
		showRawSource: showRawSource,
		avoidBuggyClippers: avoidBuggyClippers ?? this.avoidBuggyClippers,
		onEnter: onEnter,
		onExit: onExit,
		ownLine: ownLine ?? this.ownLine,
		shrinkWrap: shrinkWrap ?? this.shrinkWrap,
		highlightString: highlightString,
		maxLines: maxLines ?? this.maxLines
	);
}

abstract class PostSpan {
	List<int> referencedPostIds(String forBoard) {
		return [];
	}
	InlineSpan build(BuildContext context, PostSpanRenderOptions options);
	String buildText();
	bool willConsumeEntireLine(PostSpanRenderOptions options) => false;
}

class PostNodeSpan extends PostSpan {
	List<PostSpan> children;
	PostNodeSpan(this.children);

	final Map<String, List<int>> _referencedPostIds = {};
	@override
	List<int> referencedPostIds(String forBoard) {
		return _referencedPostIds.putIfAbsent(forBoard, () {
			return children.expand((child) => child.referencedPostIds(forBoard)).toList();
		});
	}

	@override
	InlineSpan build(context, options) {
		final ownLineOptions = options.copyWith(ownLine: true);
		final renderChildren = <InlineSpan>[];
		int lines = 0;
		for (int i = 0; i < children.length && lines < options.maxLines; i++) {
			if ((i == 0 || children[i - 1] is PostLineBreakSpan) && (i == children.length - 1 || children[i + 1] is PostLineBreakSpan)) {
				renderChildren.add(children[i].build(context, ownLineOptions));
				if (children[i].willConsumeEntireLine(ownLineOptions) && i + 1 < children.length) {
					i++;
				}
			}
			else {
				renderChildren.add(children[i].build(context, options));
			}
			if (children[i] is PostLineBreakSpan) {
				lines++;
			}
		}
		return TextSpan(
			children: renderChildren
		);
	}

	Widget buildWidget(BuildContext context, PostSpanRenderOptions options, {Widget? preInjectRow, InlineSpan? postInject}) {
		final rows = <List<InlineSpan>>[[]];
		int lines = preInjectRow != null ? 2 : 1;
		for (int i = 0; i < children.length && lines < options.maxLines; i++) {
			if (children[i] is PostLineBreakSpan) {
				rows.add([]);
				lines++;
			}
			else if ((i == 0 || children[i - 1] is PostLineBreakSpan) && (i == children.length - 1 || children[i + 1] is PostLineBreakSpan)) {
				rows.last.add(children[i].build(context, options.copyWith(ownLine: true)));
			}
			else {
				rows.last.add(children[i].build(context, options));
			}
		}
		if (postInject != null) {
			rows.last.add(postInject);
		}
		if (rows.last.isEmpty) {
			rows.removeLast();
		}
		final widgetRows = <Widget>[
			if (preInjectRow != null) preInjectRow
		];
		for (final row in rows) {
			if (row.isEmpty) {
				widgetRows.add(const Text.rich(TextSpan(text: '')));
			}
			else if (row.length == 1) {
				widgetRows.add(Text.rich(row.first));
			}
			else {
				widgetRows.add(Text.rich(TextSpan(children: row)));
			}
		}
		return Column(
			mainAxisSize: MainAxisSize.min,
			crossAxisAlignment: CrossAxisAlignment.start,
			children: widgetRows
		);
	}

	@override
	String buildText() {
		return children.map((x) => x.buildText()).join('');
	}
}

class PostTextSpan extends PostSpan {
	final String text;
	final bool underlined;
	PostTextSpan(this.text, {this.underlined = false});

	@override
	InlineSpan build(context, options) {
		final children = <TextSpan>[];
		final str = context.read<EffectiveSettings>().filterProfanity(text);
		if (options.highlightString != null) {
			final escapedHighlight = options.highlightString!.replaceAllMapped(RegExp(r'[.*+?^${}()|[\]\\]'), (m) => '\\${m.group(0)}');
			final nonHighlightedParts = str.split(RegExp(escapedHighlight, caseSensitive: false));
			int pos = 0;
			for (int i = 0; i < nonHighlightedParts.length; i++) {
				pos += nonHighlightedParts[i].length;
				children.add(TextSpan(
					text: nonHighlightedParts[i],
					recognizer: options.recognizer
				));
				if ((i + 1) < nonHighlightedParts.length) {
					children.add(TextSpan(
						text: str.substring(pos, pos + options.highlightString!.length),
						style: const TextStyle(
							color: Colors.black,
							backgroundColor: Colors.yellow
						),
						recognizer: options.recognizer
					));
					pos += options.highlightString!.length;
				}
			}
		}
		else {
			children.add(TextSpan(
				text: str,
				recognizer: options.recognizer
			));
		}
		return TextSpan(
			children: children,
			style: underlined ? options.baseTextStyle.copyWith(
				color: options.overrideTextColor,
				decoration: TextDecoration.underline
			) : options.baseTextStyle,
			recognizer: options.recognizer,
			onEnter: options.onEnter,
			onExit: options.onExit
		);
	}

	@override
	String buildText() {
		return text;
	}
}

class PostLineBreakSpan extends PostTextSpan {
	PostLineBreakSpan() : super('\n');
}

class PostQuoteSpan extends PostSpan {
	final PostSpan child;
	PostQuoteSpan(this.child);

	@override
	InlineSpan build(context, options) {
		return child.build(context, options.copyWith(
			baseTextStyle: options.baseTextStyle.copyWith(color: context.read<EffectiveSettings>().theme.quoteColor)
		));
	}

	@override
	String buildText() {
		return child.buildText();
	}
}

class PostQuoteLinkSpan extends PostSpan {
	final String board;
	int? threadId;
	final int postId;
	final bool dead;
	PostQuoteLinkSpan({
		required this.board,
		this.threadId,
		required this.postId,
		required this.dead
	}) {
		if (!dead && threadId == null) {
			throw StateError('A live QuoteLinkSpan should know its threadId');
		}
	}
	@override
	List<int> referencedPostIds(String forBoard) {
		if (forBoard == board) {
			return [postId];
		}
		return [];
	}
	Tuple2<InlineSpan, TapGestureRecognizer> _buildCrossThreadLink(BuildContext context, PostSpanRenderOptions options) {
		String text = '>>';
		if (context.watch<PostSpanZoneData>().thread.board != board) {
			text += '/$board/';
		}
		text += '$postId';
		if (options.showCrossThreadLabel) {
			text += ' (Cross-thread)';
		}
		final recognizer = options.overridingRecognizer ?? (TapGestureRecognizer()..onTap = () {
			(context.read<GlobalKey<NavigatorState>?>()?.currentState ?? Navigator.of(context)).push(FullWidthCupertinoPageRoute(
				builder: (ctx) => ImageboardScope(
					imageboardKey: null,
					imageboard: context.read<Imageboard>(),
					child: ThreadPage(
						thread: ThreadIdentifier(board, threadId!),
						initialPostId: postId,
						initiallyUseArchive: dead,
						boardSemanticId: -1
					)
				),
				showAnimations: context.read<EffectiveSettings>().showAnimations
			));
		});
		return Tuple2(TextSpan(
			text: text,
			style: options.baseTextStyle.copyWith(
				color: options.overrideTextColor ?? CupertinoTheme.of(context).textTheme.actionTextStyle.color,
				decoration: TextDecoration.underline
			),
			recognizer: recognizer
		), recognizer);
	}
	Tuple2<InlineSpan, TapGestureRecognizer> _buildDeadLink(BuildContext context, PostSpanRenderOptions options) {
		final zone = context.watch<PostSpanZoneData>();
		String text = '>>$postId';
		if (zone.postFromArchiveError(postId) != null) {
			text += ' (Error: ${zone.postFromArchiveError(postId)})';
		}
		else if (zone.isLoadingPostFromArchive(postId)) {
			text += ' (Loading...)';
		}
		else {
			text += ' (Dead)';
		}
		final recognizer = options.overridingRecognizer ?? (TapGestureRecognizer()..onTap = () {
			if (!zone.isLoadingPostFromArchive(postId)) zone.loadPostFromArchive(postId);
		});
		return Tuple2(TextSpan(
			text: text,
			style: options.baseTextStyle.copyWith(
				color: options.overrideTextColor ?? CupertinoTheme.of(context).textTheme.actionTextStyle.color,
				decoration: TextDecoration.underline
			),
			recognizer: recognizer
		), recognizer);
	}
	Tuple2<InlineSpan, TapGestureRecognizer> _buildNormalLink(BuildContext context, PostSpanRenderOptions options) {
		final zone = context.watch<PostSpanZoneData>();
		String text = '>>$postId';
		if (postId == threadId) {
			text += ' (OP)';
		}
		if (zone.threadState?.youIds.contains(postId) ?? false) {
			text += ' (You)';
		}
		final linkedPost = zone.thread.posts.tryFirstWhere((p) => p.id == postId);
		if (linkedPost != null && Filter.of(context).filter(linkedPost)?.type == FilterResultType.hide) {
			text += ' (Hidden)';
		}
		final bool expandedImmediatelyAbove = zone.shouldExpandPost(postId) || zone.stackIds.length > 1 && zone.stackIds.elementAt(zone.stackIds.length - 2) == postId;
		final bool expandedSomewhereAbove = expandedImmediatelyAbove || zone.stackIds.contains(postId);
		final recognizer = options.overridingRecognizer ?? (TapGestureRecognizer()..onTap = () {
			if (!zone.stackIds.contains(postId)) {
				if (!context.read<EffectiveSettings>().supportMouse.value) {
					WeakNavigator.push(context, PostsPage(
							zone: zone.childZoneFor(postId),
							postsIdsToShow: [postId],
							postIdForBackground: zone.stackIds.last,
						)
					);
				}
				else {
					zone.toggleExpansionOfPost(postId);
				}
			}
		});
		return Tuple2(TextSpan(
			text: text,
			style: options.baseTextStyle.copyWith(
				color: options.overrideTextColor ?? (expandedImmediatelyAbove ? CupertinoTheme.of(context).textTheme.actionTextStyle.color?.shiftSaturation(-0.5) : CupertinoTheme.of(context).textTheme.actionTextStyle.color),
				decoration: TextDecoration.underline,
				decorationStyle: expandedSomewhereAbove ? TextDecorationStyle.dashed : null
			),
			recognizer: recognizer,
			onEnter: options.onEnter,
			onExit: options.onExit
		), recognizer);
	}
	Tuple2<InlineSpan, TapGestureRecognizer> _build(BuildContext context, PostSpanRenderOptions options) {
		final zone = context.watch<PostSpanZoneData>();
		if (dead && threadId == null) {
			// Dead links do not know their thread
			final thisPostLoaded = zone.postFromArchive(postId);
			if (thisPostLoaded != null) {
				threadId = thisPostLoaded.threadId;
			}
			else {
				return _buildDeadLink(context, options);
			}
		}

		if (threadId != null && (board != zone.thread.board || threadId != zone.thread.id)) {
			return _buildCrossThreadLink(context, options);
		}
		else {
			// Normal link
			final span = _buildNormalLink(context, options);
			final thisPostInThread = zone.thread.posts.where((p) => p.id == postId);
			if (thisPostInThread.isEmpty || zone.shouldExpandPost(postId)) {
				return span;
			}
			else {
				final popup = HoverPopup(
					style: HoverPopupStyle.floating,
					anchor: const Offset(30, -80),
					popup: ChangeNotifierProvider.value(
						value: zone,
						child: DecoratedBox(
							decoration: BoxDecoration(
								border: Border.all(color: CupertinoTheme.of(context).primaryColor)
							),
							position: DecorationPosition.foreground,
							child: PostRow(
								post: thisPostInThread.first,
								shrinkWrap: true
							)
						)
					),
					child: Text.rich(
						span.item1,
						textScaleFactor: 1
					)
				);
				return Tuple2(WidgetSpan(
					child: willConsumeEntireLine(options) ? IntrinsicHeight(
						child: Row(
							children: [
								popup,
								Expanded(
									child: GestureDetector(
										onTap: span.item2.onTap
									)
								)
							]
						)
					) : popup
				), span.item2);
			}
		}
	}
	@override
	build(context, options) {
		final zone = context.watch<PostSpanZoneData>();
		final pair = _build(context, options);
		final span = willConsumeEntireLine(options) ? TextSpan(
			children: [
				pair.item1,
				WidgetSpan(child: Row())
			],
			recognizer: pair.item2
		) : pair.item1;
		if (options.addExpandingPosts && (threadId == zone.thread.id && board == zone.thread.board)) {
			return TextSpan(
				children: [
					span,
					WidgetSpan(child: ExpandingPost(id: postId))
				]
			);
		}
		else {
			return span;
		}
	}

	@override
	String buildText() {
		return '>>$postId';
	}

	@override
	bool willConsumeEntireLine(PostSpanRenderOptions options) => (options.ownLine && !options.shrinkWrap);
}

class PostBoardLink extends PostSpan {
	final String board;
	PostBoardLink(this.board);
	@override
	build(context, options) {
		return TextSpan(
			text: '>>/$board/',
			style: options.baseTextStyle.copyWith(
				color: options.overrideTextColor ?? CupertinoTheme.of(context).textTheme.actionTextStyle.color,
				decoration: TextDecoration.underline
			),
			recognizer: options.overridingRecognizer ?? (TapGestureRecognizer()..onTap = () async {
				(context.read<GlobalKey<NavigatorState>?>()?.currentState ?? Navigator.of(context)).push(FullWidthCupertinoPageRoute(
					builder: (ctx) => ImageboardScope(
					imageboardKey: null,
					imageboard: context.read<Imageboard>(),
						child: BoardPage(
							initialBoard: context.read<Persistence>().getBoard(board),
							semanticId: -1
						)
					),
					showAnimations: context.read<EffectiveSettings>().showAnimations
				));
			}),
			onEnter: options.onEnter,
			onExit: options.onExit
		);
	}

	@override
	String buildText() {
		return '>>/$board/';
	}
}

class _DetectLanguageParam {
	final String text;
	final SendPort sendPort;
	const _DetectLanguageParam(this.text, this.sendPort);
}

void _detectLanguageIsolate(_DetectLanguageParam param) {
	final result = highlight.parse(param.text, autoDetection: true);
	param.sendPort.send(result.language);
}

class PostCodeSpan extends PostSpan {
	final String text;

	PostCodeSpan(this.text);

	@override
	build(context, options) {
		final zone = context.watch<PostSpanZoneData>();
		final result = zone.getFutureForComputation(
			id: 'languagedetect $text',
			work: () async {
				final receivePort = ReceivePort();
				String? language;
				if (kDebugMode) {
					language = highlight.parse(text, autoDetection: true).language;
				}
				else {
					await Isolate.spawn(_detectLanguageIsolate, _DetectLanguageParam(text, receivePort.sendPort));
					language = await receivePort.first as String?;
				}
				const theme = atomOneDarkReasonableTheme;
				final nodes = highlight.parse(text.replaceAll('\t', ' ' * 4), language: language ?? 'plaintext').nodes!;
				final List<TextSpan> spans = [];
				List<TextSpan> currentSpans = spans;
				List<List<TextSpan>> stack = [];

				traverse(Node node) {
					if (node.value != null) {
						currentSpans.add(node.className == null
								? TextSpan(text: node.value)
								: TextSpan(text: node.value, style: theme[node.className!]));
					} else if (node.children != null) {
						List<TextSpan> tmp = [];
						currentSpans.add(TextSpan(children: tmp, style: theme[node.className!]));
						stack.add(currentSpans);
						currentSpans = tmp;

						for (final n in node.children!) {
							traverse(n);
							if (n == node.children!.last) {
								currentSpans = stack.isEmpty ? spans : stack.removeLast();
							}
						}
					}
				}

				for (var node in nodes) {
					traverse(node);
				}

				return spans;
			}
		);
		final child = RichText(
			text: TextSpan(
				style: GoogleFonts.ibmPlexMono(textStyle: options.baseTextStyle),
				children: result.data ?? [
					TextSpan(text: text)
				]
			),
			softWrap: false
		);
		return WidgetSpan(
			child: Container(
				padding: const EdgeInsets.all(8),
				decoration: const BoxDecoration(
					color: Colors.black,
					borderRadius: BorderRadius.all(Radius.circular(8))
				),
				child: options.avoidBuggyClippers ? child : SingleChildScrollView(
					scrollDirection: Axis.horizontal,
					child: child
				)
			)
		);
	}

	@override
	String buildText() {
		return '[code]$text[/code]';
	}
}

class PostSpoilerSpan extends PostSpan {
	final PostSpan child;
	final int id;
	PostSpoilerSpan(this.child, this.id);
	@override
	build(context, options) {
		final zone = context.watch<PostSpanZoneData>();
		final showSpoiler = zone.shouldShowSpoiler(id);
		final toggleRecognizer = TapGestureRecognizer()..onTap = () {
			zone.toggleShowingOfSpoiler(id);
		};
		final hiddenColor = DefaultTextStyle.of(context).style.color;
		final visibleColor = CupertinoTheme.of(context).scaffoldBackgroundColor;
		onEnter(_) => zone.showSpoiler(id);
		onExit(_) => zone.hideSpoiler(id);
		return TextSpan(
			children: [child.build(context, PostSpanRenderOptions(
				recognizer: toggleRecognizer,
				overrideRecognizer: !showSpoiler,
				overrideTextColor: showSpoiler ? visibleColor : hiddenColor,
				showCrossThreadLabel: options.showCrossThreadLabel,
				onEnter: onEnter,
				onExit: onExit
			))],
			style: options.baseTextStyle.copyWith(
				backgroundColor: hiddenColor,
				color: showSpoiler ? visibleColor : null
			),
			recognizer: toggleRecognizer,
			onEnter: onEnter,
			onExit: onExit
		);
	}

	@override
	String buildText() {
		return '[spoiler]${child.buildText()}[/spoiler]';
	}
}

class PostLinkSpan extends PostSpan {
	final String url;
	PostLinkSpan(this.url);
	@override
	build(context, options) {
		final zone = context.watch<PostSpanZoneData>();
		final settings = context.watch<EffectiveSettings>();
		// Remove trailing bracket or other punctuation
		final cleanedUrl = url.replaceAllMapped(
			RegExp(r'(\.[A-Za-z0-9\-._~]+)[^A-Za-z0-9\-._~\.\/?]+$'),
			(m) => m.group(1)!
		);
		final cleanedUri = Uri.tryParse(cleanedUrl);
		if (!options.showRawSource && settings.useEmbeds) {
			final check = zone.getFutureForComputation(
				id: 'embedcheck $url',
				work: () => embedPossible(
					context: context,
					url: url
				)
			);
			if (check.data == true) {
				final snapshot = zone.getFutureForComputation(
					id: 'noembed $url',
					work: () => loadEmbedData(
						context: context,
						url: url
					)
				);
				Widget buildEmbed(List<Widget> children) => Padding(
					padding: const EdgeInsets.only(top: 8, bottom: 8),
					child: ClipRRect(
						borderRadius: const BorderRadius.all(Radius.circular(8)),
						child: Container(
							padding: const EdgeInsets.all(8),
							color: CupertinoTheme.of(context).barBackgroundColor,
							child: Row(
								crossAxisAlignment: CrossAxisAlignment.center,
								mainAxisSize: MainAxisSize.min,
								children: children
							)
						)
					)
				);
				Widget? tapChild;
				if (snapshot.connectionState == ConnectionState.waiting) {
					tapChild = buildEmbed([
						const SizedBox(
							width: 75,
							height: 75,
							child: CupertinoActivityIndicator()
						),
						const SizedBox(width: 16),
						Flexible(
							child: Text(url, style: const TextStyle(decoration: TextDecoration.underline), textScaleFactor: 1)
						),
						const SizedBox(width: 16)
					]);
				}
				String? byline = snapshot.data?.provider;
				if (snapshot.data?.author != null && !(snapshot.data?.title != null && snapshot.data!.title!.contains(snapshot.data!.author!))) {
					byline = byline == null ? snapshot.data?.author : '${snapshot.data?.author} - $byline';
				}
				if (snapshot.data?.thumbnailWidget != null || snapshot.data?.thumbnailUrl != null) {
					tapChild = buildEmbed([
						ClipRRect(
							borderRadius: const BorderRadius.all(Radius.circular(8)),
							child: snapshot.data?.thumbnailWidget ?? ExtendedImage.network(
								snapshot.data!.thumbnailUrl!,
								cache: true,
								width: 75,
								height: 75,
								fit: BoxFit.cover
							)
						),
						const SizedBox(width: 16),
						Flexible(
							child: Column(
								crossAxisAlignment: CrossAxisAlignment.start,
								children: [
									if (snapshot.data?.title != null) Text(snapshot.data!.title!, style: TextStyle(
										color: CupertinoTheme.of(context).primaryColor
									), textScaleFactor: 1),
									if (byline != null) Text(byline, style: const TextStyle(color: Colors.grey), textScaleFactor: 1)
								]
							)
						),
						if (cleanedUri != null && settings.hostsToOpenExternally.any((s) => cleanedUri.host.endsWith(s))) const Padding(
							padding: EdgeInsets.only(left: 16),
							child: Icon(Icons.launch_rounded)
						),
						const SizedBox(width: 16)
					]);
				}

				if (tapChild != null) {
					onTap() {
						openBrowser(context, cleanedUri!);
					}
					return WidgetSpan(
						alignment: PlaceholderAlignment.middle,
						child: options.avoidBuggyClippers ? GestureDetector(
							onTap: onTap,
							child: tapChild
						) : CupertinoButton(
							padding: EdgeInsets.zero,
							onPressed: onTap,
							child: tapChild
						)
					);
				}
			}
		}
		return TextSpan(
			text: url,
			style: options.baseTextStyle.copyWith(
				decoration: TextDecoration.underline
			),
			recognizer: options.overridingRecognizer ?? (TapGestureRecognizer()..onTap = () => openBrowser(context, Uri.parse(cleanedUrl))),
			onEnter: options.onEnter,
			onExit: options.onExit
		);
	}

	@override
	String buildText() {
		return url;
	}
}

class PostCatalogSearchSpan extends PostSpan {
	final String board;
	final String query;
	PostCatalogSearchSpan({
		required this.board,
		required this.query
	});
	@override
	build(context, options) {
		return TextSpan(
			text: '>>/$board/$query',
			style: options.baseTextStyle.copyWith(
				decoration: TextDecoration.underline,
				color: CupertinoTheme.of(context).textTheme.actionTextStyle.color
			),
			recognizer: TapGestureRecognizer()..onTap = () => (context.read<GlobalKey<NavigatorState>?>()?.currentState ?? Navigator.of(context)).push(FullWidthCupertinoPageRoute(
				builder: (ctx) => ImageboardScope(
					imageboardKey: null,
					imageboard: context.read<Imageboard>(),
					child: BoardPage(
						initialBoard: context.read<Persistence>().getBoard(board),
						initialSearch: query,
						semanticId: -1
					)
				),
				showAnimations: context.read<EffectiveSettings>().showAnimations
			)),
			onEnter: options.onEnter,
			onExit: options.onExit
		);
	}

	@override
	String buildText() {
		return '>>/$board/$query';
	}
}

class PostTeXSpan extends PostSpan {
	final String tex;
	PostTeXSpan(this.tex);
	@override
	build(context, options) {
		final child = TexWidget(
			tex: tex,
			color: options.overrideTextColor ?? options.baseTextStyle.color
		);
		return options.showRawSource ? TextSpan(
			text: buildText()
		) : WidgetSpan(
			alignment: PlaceholderAlignment.middle,
			child: options.avoidBuggyClippers ? child : SingleChildScrollView(
				scrollDirection: Axis.horizontal,
				child: child
			)
		);
	}
	@override
	String buildText() => '[math]$tex[/math]';
}

class PostInlineImageSpan extends PostSpan {
	final String src;
	final int width;
	final int height;
	PostInlineImageSpan({
		required this.src,
		required this.width,
		required this.height
	});
	@override
	build(context, options) {
		return WidgetSpan(
			child: SizedBox(
				width: width.toDouble(),
				height: height.toDouble(),
				child: ExtendedImage.network(
					src,
					cache: true,
					enableLoadState: false
				)
			),
			alignment: PlaceholderAlignment.bottom
		);
	}
	@override
	String buildText() => '';
}

class PostColorSpan extends PostSpan {
	final PostSpan child;
	final Color color;
	
	PostColorSpan(this.child, this.color);
	@override
	build(context, options) {
		return child.build(context, options.copyWith(
			baseTextStyle: options.baseTextStyle.copyWith(color: color)
		));
	}
	@override
	buildText() => child.buildText();
}

class PostBoldSpan extends PostSpan {
	final PostSpan child;

	PostBoldSpan(this.child);
	@override
	build(context, options) {
		return child.build(context, options.copyWith(
			baseTextStyle: options.baseTextStyle.copyWith(fontWeight: FontWeight.bold)
		));
	}
	@override
	buildText() => child.buildText();
}

class PostPopupSpan extends PostSpan {
	final PostSpan popup;
	final String title;
	PostPopupSpan({
		required this.popup,
		required this.title
	});
	@override
	build(context, options) {
		return TextSpan(
			text: 'Show $title',
			style: options.baseTextStyle.copyWith(
				decoration: TextDecoration.underline
			),
			recognizer: options.overridingRecognizer ?? TapGestureRecognizer()..onTap = () {
				showCupertinoModalPopup(
					context: context,
					barrierDismissible: true,
					builder: (context) => CupertinoActionSheet(
						title: Text(title),
						message: Text.rich(
							popup.build(context, options),
							textAlign: TextAlign.left,
						),
						actions: [
							CupertinoActionSheetAction(
								child: const Text('Close'),
								onPressed: () {
									Navigator.of(context).pop(true);
								}
							)
						]
					)
				);
			}
		);
	}

	@override
	buildText() => '$title\n${popup.buildText()}';
}

class PostTableSpan extends PostSpan {
	final List<List<String>> rows;
	PostTableSpan(this.rows);
	@override
	build(context, options) {
		return WidgetSpan(
			child: Table(
				children: rows.map((row) => TableRow(
					children: row.map((col) => TableCell(
						child: Text(
							col,
							textAlign: TextAlign.left,
							textScaleFactor: 1
						)
					)).toList()
				)).toList()
			)
		);
	}
	@override
	buildText() => rows.map((r) => r.join(', ')).join('\n');
}

class PostSpanZone extends StatelessWidget {
	final int postId;
	final WidgetBuilder builder;

	const PostSpanZone({
		required this.postId,
		required this.builder,
		Key? key
	}) : super(key: key);

	@override
	Widget build(BuildContext context) {
		return ChangeNotifierProvider<PostSpanZoneData>.value(
			value: context.read<PostSpanZoneData>().childZoneFor(postId),
			child: Builder(
				builder: builder
			)
		);
	}
}

abstract class PostSpanZoneData extends ChangeNotifier {
	final Map<int, PostSpanZoneData> _children = {};
	Thread get thread;
	ImageboardSite get site;
	Iterable<int> get stackIds;
	PersistentThreadState? get threadState;
	ValueChanged<Post>? get onNeedScrollToPost;
	bool disposed = false;

	final Map<int, bool> _shouldExpandPost = {};
	bool shouldExpandPost(int id) {
		return _shouldExpandPost[id] ?? false;
	}
	void toggleExpansionOfPost(int id) {
		_shouldExpandPost[id] = !shouldExpandPost(id);
		if (!_shouldExpandPost[id]!) {
			_children[id]?.unExpandAllPosts();
		}
		notifyListeners();
	}
	void unExpandAllPosts() => throw UnimplementedError();
	bool isLoadingPostFromArchive(int id) => false;
	Future<void> loadPostFromArchive(int id) => throw UnimplementedError();
	Post? postFromArchive(int id) => null;
	String? postFromArchiveError(int id) => null;
	final Map<int, bool> _shouldShowSpoiler = {};
	bool shouldShowSpoiler(int id) {
		return _shouldShowSpoiler[id] ?? false;
	}
	void showSpoiler(int id) {
		_shouldShowSpoiler[id] = true;
		notifyListeners();
	}
	void hideSpoiler(int id) {
		_shouldShowSpoiler[id] = false;
		notifyListeners();
	}
	void toggleShowingOfSpoiler(int id) {
		_shouldShowSpoiler[id] = !shouldShowSpoiler(id);
		notifyListeners();
	}

	final Map<String, AsyncSnapshot> _futures = {};
	static final Map<String, AsyncSnapshot> _globalFutures = {};
	AsyncSnapshot<T> getFutureForComputation<T>({
		required String id,
		required Future<T> Function() work
	}) {
		if (_globalFutures.containsKey(id)) {
			return _globalFutures[id]! as AsyncSnapshot<T>;
		}
		if (!_futures.containsKey(id)) {
			_futures[id] = AsyncSnapshot<T>.waiting();
			() async {
				try {
					final data = await work();
					_futures[id] = AsyncSnapshot<T>.withData(ConnectionState.done, data);
				}
				catch (e) {
					_futures[id] = AsyncSnapshot<T>.withError(ConnectionState.done, e);
				}
				_globalFutures[id] = _futures[id]!;
				if (!disposed) {
					notifyListeners();
				}
			}();
		}
		return _futures[id] as AsyncSnapshot<T>;
	}

	PostSpanZoneData childZoneFor(int postId) {
		if (!_children.containsKey(postId)) {
			_children[postId] = PostSpanChildZoneData(
				parent: this,
				postId: postId
			);
		}
		return _children[postId]!;
	}

	void notifyAllListeners() {
		notifyListeners();
		for (final child in _children.values) {
			child.notifyAllListeners();
		}
	}

	@override
	void dispose() {
		for (final zone in _children.values) {
			zone.dispose();	
		}
		super.dispose();
		disposed = true;
	}
}

class PostSpanChildZoneData extends PostSpanZoneData {
	final int postId;
	final PostSpanZoneData parent;

	PostSpanChildZoneData({
		required this.parent,
		required this.postId
	});

	@override
	Thread get thread => parent.thread;

	@override
	ImageboardSite get site => parent.site;

	@override
	PersistentThreadState? get threadState => parent.threadState;

	@override
	ValueChanged<Post>? get onNeedScrollToPost => parent.onNeedScrollToPost;

	@override
	Iterable<int> get stackIds {
		return parent.stackIds.followedBy([postId]);
	}

	@override
	void unExpandAllPosts() {
		_shouldExpandPost.updateAll((key, value) => false);
		for (final child in _children.values) {
			child.unExpandAllPosts();
		}
		notifyListeners();
	}

	@override
	bool isLoadingPostFromArchive(int id) => parent.isLoadingPostFromArchive(id);
	@override
	Future<void> loadPostFromArchive(int id) => parent.loadPostFromArchive(id);
	@override
	Post? postFromArchive(int id) => parent.postFromArchive(id);
	@override
	String? postFromArchiveError(int id) => parent.postFromArchiveError(id);
}


class PostSpanRootZoneData extends PostSpanZoneData {
	@override
	Thread thread;
	@override
	final ImageboardSite site;
	@override
	final PersistentThreadState? threadState;
	@override
	final ValueChanged<Post>? onNeedScrollToPost;
	final Map<int, bool> _isLoadingPostFromArchive = {};
	final Map<int, Post> _postsFromArchive = {};
	final Map<int, String> _postFromArchiveErrors = {};
	final Iterable<int> semanticRootIds;

	PostSpanRootZoneData({
		required this.thread,
		required this.site,
		this.threadState,
		this.onNeedScrollToPost,
		this.semanticRootIds = const []
	});

	@override
	Iterable<int> get stackIds => semanticRootIds;

	@override
	bool isLoadingPostFromArchive(int id) {
		return _isLoadingPostFromArchive[id] ?? false;
	}

	@override
	Future<void> loadPostFromArchive(int id) async {
		try {
			_postFromArchiveErrors.remove(id);
			_isLoadingPostFromArchive[id] = true;
			notifyListeners();
			_postsFromArchive[id] = await site.getPostFromArchive(thread.board, id);
			_postsFromArchive[id]!.replyIds = thread.posts.where((p) => p.span.referencedPostIds(thread.board).contains(id)).map((p) => p.id).toList();
			notifyListeners();
		}
		catch (e, st) {
			print('Error getting post from archive');
			print(e);
			print(st);
			_postFromArchiveErrors[id] = e.toStringDio();
		}
		_isLoadingPostFromArchive[id] = false;
		notifyAllListeners();
	}

	@override
	Post? postFromArchive(int id) {
		return _postsFromArchive[id];
	}

	@override
	String? postFromArchiveError(int id) {
		return _postFromArchiveErrors[id];
	}
}

class ExpandingPost extends StatelessWidget {
	final int id;
	const ExpandingPost({
		required this.id,
		Key? key
	}) : super(key: key);
	
	@override
	Widget build(BuildContext context) {
		final zone = context.watch<PostSpanZoneData>();
		final post = zone.thread.posts.tryFirstWhere((p) => p.id == id) ?? zone.postFromArchive(id);
		if (post == null) {
			print('Could not find post with ID $id in zone for ${zone.thread.id}');
		}
		return zone.shouldExpandPost(id) ? TransformedMediaQuery(
			transformation: (mq) => mq.copyWith(textScaleFactor: 1),
			child: (post == null) ? Center(
				child: Text('Could not find /${zone.thread.board}/$id')
			) : Row(
				children: [
					Flexible(
						child: Padding(
							padding: const EdgeInsets.only(top: 8, bottom: 8),
							child: DecoratedBox(
								decoration: BoxDecoration(
									border: Border.all(color: CupertinoTheme.of(context).primaryColor)
								),
								position: DecorationPosition.foreground,
								child: PostRow(
									post: post,
									onThumbnailTap: (attachment) {
										showGallery(
											context: context,
											attachments: [attachment],
											semanticParentIds: zone.stackIds
										);
									},
									shrinkWrap: true
								)
							)
						)
					)
				]
			)
		) : const SizedBox.shrink();
	}
}

String _makeAttachmentInfo({
	required Post post,
	required EffectiveSettings settings
}) {
	String text = '';
	for (final attachment in post.attachments) {
		if (settings.showFilenameOnPosts) {
			text += '${attachment.filename} ';
		}
		if (settings.showFilesizeOnPosts || settings.showFileDimensionsOnPosts) {
			text += '(';
			bool firstItemPassed = false;
			if (settings.showFilesizeOnPosts) {
				text += '${((attachment.sizeInBytes ?? 0) / 1024).round()} KB';
				firstItemPassed = true;
			}
			if (settings.showFileDimensionsOnPosts) {
				if (firstItemPassed) {
					text += ', ';
				}
				text += '${attachment.width}x${attachment.height}';
			}
			text += ') ';
		}
	}
	return text;
}

List<InlineSpan> buildPostInfoRow({
	required Post post,
	required bool isYourPost,
	required bool showSiteIcon,
	required bool showBoardName,
	required EffectiveSettings settings,
	required ImageboardSite site,
	required BuildContext context,
	required PostSpanZoneData zone,
	bool interactive = true
}) {
	return [
		for (final field in settings.postDisplayFieldOrder)
			if (field == PostDisplayField.name) ...[
				if (settings.showNameOnPosts && !(settings.hideDefaultNamesOnPosts && post.name == site.defaultUsername)) TextSpan(
					text: settings.filterProfanity(post.name) + (isYourPost ? ' (You)' : ''),
					style: TextStyle(fontWeight: FontWeight.w600, color: isYourPost ? CupertinoTheme.of(context).textTheme.actionTextStyle.color : null)
				)
				else if (isYourPost) TextSpan(
					text: '(You)',
					style: TextStyle(fontWeight: FontWeight.w600, color: CupertinoTheme.of(context).textTheme.actionTextStyle.color)
				),
				if (settings.showTripOnPosts && post.trip != null) TextSpan(
					text: '${settings.filterProfanity(post.trip!)} ',
					style: TextStyle(color: isYourPost ? CupertinoTheme.of(context).textTheme.actionTextStyle.color : null)
				)
				else if (settings.showNameOnPosts || isYourPost) const TextSpan(text: ' '),
				if (post.capcode != null) TextSpan(
					text: '## ${post.capcode} ',
					style: TextStyle(fontWeight: FontWeight.w600, color: settings.theme.quoteColor.shiftHue(200).shiftSaturation(-0.3))
				)
			]
			else if (field == PostDisplayField.posterId && post.posterId != null) ...[
				IDSpan(
					id: post.posterId!,
					onPressed: interactive ? () => WeakNavigator.push(context, PostsPage(
						postsIdsToShow: zone.thread.posts.where((p) => p.posterId == post.posterId).map((p) => p.id).toList(),
						zone: zone
					)) : null
				),
				const TextSpan(text: ' ')
			]
			else if (field == PostDisplayField.attachmentInfo && post.attachments.isNotEmpty) TextSpan(
				text: _makeAttachmentInfo(
					post: post,
					settings: settings
				),
				style: TextStyle(
					color: CupertinoTheme.of(context).primaryColorWithBrightness(0.8)
				)
			)
			else if (field == PostDisplayField.pass && settings.showPassOnPosts && post.passSinceYear != null) ...[
				PassSinceSpan(
					sinceYear: post.passSinceYear!,
					site: site
				),
				const TextSpan(text: ' ')
			]
			else if (field == PostDisplayField.flag && settings.showFlagOnPosts && post.flag != null) ...[
				FlagSpan(post.flag!),
				const TextSpan(text: ' ')
			]
			else if (field == PostDisplayField.countryName && settings.showCountryNameOnPosts && post.flag != null) TextSpan(
				text: '${post.flag!.name} ',
				style: const TextStyle(
					fontStyle: FontStyle.italic
				)
			)
			else if (field == PostDisplayField.absoluteTime && settings.showAbsoluteTimeOnPosts) TextSpan(
				text: '${formatTime(post.time)} '
			)
			else if (field == PostDisplayField.relativeTime && settings.showRelativeTimeOnPosts) TextSpan(
				text: '${formatRelativeTime(post.time)} ago '
			)
			else if (field == PostDisplayField.postId) ...[
				if (showSiteIcon) const WidgetSpan(
					alignment: PlaceholderAlignment.middle,
					child: ImageboardIcon()
				),
				TextSpan(
					text: '${showBoardName ? '/${post.board}/' : ''}${post.id} ',
					style: TextStyle(color: CupertinoTheme.of(context).primaryColor.withOpacity(0.5)),
					recognizer: interactive ? (TapGestureRecognizer()..onTap = () {
						context.read<GlobalKey<ReplyBoxState>>().currentState?.onTapPostId(post.id);
					}) : null
				)
			]
	];
}