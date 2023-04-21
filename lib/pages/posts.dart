import 'dart:math';

import 'package:chan/models/attachment.dart';
import 'package:chan/models/parent_and_child.dart';
import 'package:chan/models/post.dart';
import 'package:chan/pages/gallery.dart';
import 'package:chan/services/settings.dart';
import 'package:chan/util.dart';
import 'package:chan/widgets/post_row.dart';
import 'package:chan/widgets/post_spans.dart';
import 'package:chan/widgets/util.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:chan/pages/overscroll_modal.dart';

class _PostsPageItem {
	final bool stub;
	final Post? post;
	final List<ParentAndChildIdentifier>? stubIds;
	bool loading = false;

	_PostsPageItem.post(this.post) : stubIds = null, stub = false;
	_PostsPageItem.primaryStub(List<ParentAndChildIdentifier> this.stubIds) : post = null, stub = true;
	_PostsPageItem.secondaryStub(this.post) : stubIds = null, stub = true;
}

class PostsPage extends StatefulWidget {
	final PostSpanZoneData zone;
	final int? postIdForBackground;
	final List<int> postsIdsToShow;
	final ValueChanged<Post>? onTap;

	const PostsPage({
		required this.postsIdsToShow,
		this.postIdForBackground,
		required this.zone,
		this.onTap,
		Key? key
	}) : super(key: key);

	@override
	createState() => _PostsPageState();
}

class _PostsPageState extends State<PostsPage> {
	final List<_PostsPageItem> replies = [];

	@override
	void initState() {
		super.initState();
		_setReplies();
		if (replies.tryLast?.stub ?? false) {
			// If there are only stubs, load them upon opening
			_onTapStub(replies.last);
		}
	}

	Future<void> _onTapStub(_PostsPageItem reply) async {
		reply.loading = true;
		setState(() {});
		try {
			await widget.zone.onNeedUpdateWithStubItems?.call(reply.stubIds!);
			_setReplies();
		}
		catch (e) {
			alertError(context, e.toStringDio());
		}
		reply.loading = false;
		setState(() {});
	}

	void _setReplies() {
		replies.clear();
		for (final id in widget.postsIdsToShow) {
			final matchingPost = widget.zone.thread.posts.tryFirstWhere((p) => p.id == id);
			if (matchingPost != null) {
				if (matchingPost.isStub) {
					replies.add(_PostsPageItem.secondaryStub(matchingPost));
				}
				else {
					replies.add(_PostsPageItem.post(matchingPost));
				}
			}
			else {
				final archivedPost = widget.zone.postFromArchive(id);
				if (archivedPost != null) {
					replies.add(_PostsPageItem.post(archivedPost));
				}
			}
		}
		for (final method in widget.zone.postSortingMethods) {
			mergeSort<_PostsPageItem>(replies, compare: (a, b) => method(a.post!, b.post!));
		}
		final stubPosts = replies.where((p) => p.stub).map((p) => p.post);
		if (stubPosts.isNotEmpty) {
			replies.add(_PostsPageItem.primaryStub(stubPosts.map((p) => ParentAndChildIdentifier(
				parentId: p!.parentId ?? p.threadId,
				childId: p.id
			)).toList()));
		}
	}

	@override
	Widget build(BuildContext context) {
		final attachments = replies.expand<Attachment>((a) => a.post?.attachments ?? []).toList();
		final subzone = widget.zone.hoistFakeRootZoneFor(0); // To avoid conflict with same semanticIds in tree
		final postForBackground = widget.postIdForBackground == null ? null : widget.zone.thread.posts.tryFirstWhere((p) => p.id == widget.postIdForBackground);
		final doubleTapScrollToReplies = context.select<EffectiveSettings, bool>((s) => s.doubleTapScrollToReplies);
		return ChangeNotifierProvider.value(
			value: subzone,
			child: OverscrollModalPage.sliver(
				background: postForBackground == null ? null : PostRow(
					post: postForBackground,
					isSelected: true
				),
				heightEstimate: 100.0 * (widget.postsIdsToShow.length - 1),
				sliver: SliverList(
					delegate: SliverChildBuilderDelegate(
						addRepaintBoundaries: false,
						childCount: max(0, (replies.length * 2) - 1),
						(context, j) {
							if (j % 2 == 0) {
								final i = j ~/ 2;
								final reply = replies[i];
								return Container(
									color: CupertinoTheme.of(context).scaffoldBackgroundColor,
									key: ValueKey(reply.post?.id ?? 0),
									child: AnimatedCrossFade(
										crossFadeState: reply.stub ? CrossFadeState.showFirst : CrossFadeState.showSecond,
										duration: const Duration(milliseconds: 350),
										sizeCurve: Curves.ease,
										firstCurve: Curves.ease,
										firstChild: reply.stubIds == null ? const SizedBox(
											height: 0,
											width: double.infinity,
										) : GestureDetector(
											onTap: () => _onTapStub(reply),
											child: Container(
												width: double.infinity,
												height: 50,
												padding: const EdgeInsets.all(8),
												color: CupertinoTheme.of(context).scaffoldBackgroundColor,
												child: Row(
													children: [
														const Spacer(),
														if (reply.loading) ...[
															const CupertinoActivityIndicator(),
															const Text(' ')
														],
														Text(
															'${reply.stubIds?.length} '
														),
														const Icon(CupertinoIcons.chevron_down, size: 20)
													]
												)
											)
										),
										secondChild: reply.post == null ? const SizedBox(
											height: 0,
											width: double.infinity
										) : PostRow(
											post: reply.post!,
											onTap: widget.onTap == null ? null : () => widget.onTap!(reply.post!),
											onDoubleTap: !doubleTapScrollToReplies || widget.zone.onNeedScrollToPost == null
																		? null : () => widget.zone.onNeedScrollToPost!(reply.post!),
											onThumbnailTap: (attachment) {
												showGallery(
													context: context,
													attachments: attachments,
													replyCounts: {
														for (final reply in replies)
															for (final attachment in reply.post!.attachments)
																attachment: reply.post!.replyIds.length
													},
													isAttachmentAlreadyDownloaded: widget.zone.threadState?.isAttachmentDownloaded,
													onAttachmentDownload: widget.zone.threadState?.didDownloadAttachment,
													initialAttachment: attachment,
													semanticParentIds: subzone.stackIds,
													onChange: (attachment) {
														Scrollable.ensureVisible(context, alignment: 0.5, duration: const Duration(milliseconds: 200));
													},
													heroOtherEndIsBoxFitCover: context.read<EffectiveSettings>().squareThumbnails
												);
											}
										)
									)
								);
							}
							return Divider(
								thickness: 1,
								height: 0,
								color: CupertinoTheme.of(context).primaryColorWithBrightness(0.2)
							);
						}
					)
				)
			)
		);
	}
}