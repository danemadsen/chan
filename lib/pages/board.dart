import 'dart:math';

import 'package:chan/models/board.dart';
import 'package:chan/pages/board_switcher.dart';
import 'package:chan/pages/thread.dart';
import 'package:chan/services/persistence.dart';
import 'package:chan/services/settings.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:chan/widgets/refreshable_list.dart';
import 'package:chan/widgets/reply_box.dart';
import 'package:chan/widgets/thread_row.dart';
import 'package:chan/widgets/util.dart';
import 'package:flutter/cupertino.dart';

import 'package:chan/models/thread.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:chan/widgets/cupertino_page_route.dart';

import 'package:chan/pages/gallery.dart';

const _OLD_THREAD_THRESHOLD = const Duration(days: 7);

class BoardPage extends StatefulWidget {
	final ImageboardBoard initialBoard;
	final bool allowChangingBoard;
	final ValueChanged<ImageboardBoard>? onBoardChanged;
	final ValueChanged<ThreadIdentifier>? onThreadSelected;
	final ThreadIdentifier? selectedThread;
	BoardPage({
		required this.initialBoard,
		this.allowChangingBoard = true,
		this.onBoardChanged,
		this.onThreadSelected,
		this.selectedThread
	});

	createState() => _BoardPageState();
}

class _BoardPageState extends State<BoardPage> {
	late ImageboardBoard board;
	bool showReplyBox = false;
	final _listController = RefreshableListController<Thread>();

	@override
	void initState() {
		super.initState();
		board = widget.initialBoard;
	}

	@override
	void didUpdateWidget(BoardPage oldWidget) {
		super.didUpdateWidget(oldWidget);
		setState(() {});
	}

	@override
	Widget build(BuildContext context) {
		final site = context.watch<ImageboardSite>();
		final settings = context.watch<EffectiveSettings>();
		return CupertinoPageScaffold(
			resizeToAvoidBottomInset: false,
			navigationBar: CupertinoNavigationBar(
				transitionBetweenRoutes: false,
				middle: GestureDetector(
					onTap: widget.allowChangingBoard ? () async {
						final newBoard = await Navigator.of(context).push<ImageboardBoard>(TransparentRoute(builder: (ctx) => BoardSwitcherPage()));
						if (newBoard != null) {
							widget.onBoardChanged?.call(newBoard);
							setState(() {
								board = newBoard;
								_listController.scrollController?.jumpTo(0);
							});
						}
					} : null,
					child: Row(
						mainAxisSize: MainAxisSize.min,
						children: [
							Text('/${board.name}/'),
							if (widget.allowChangingBoard) Icon(Icons.arrow_drop_down)
						]
					)
				),
				trailing: Row(
					mainAxisSize: MainAxisSize.min,
					children: [
						CupertinoButton(
							padding: EdgeInsets.zero,
							child: Transform(
								alignment: Alignment.center,
								transform: settings.reverseCatalogSorting ? Matrix4.rotationX(pi) : Matrix4.identity(),
								child: Icon(Icons.sort)
							),
							onPressed: () {
								showCupertinoModalPopup<DateTime>(
									context: context,
									builder: (context) => CupertinoActionSheet(
										title: const Text('Sort by...'),
										actions: {
											ThreadSortingMethod.Unsorted: 'Bump Order',
											ThreadSortingMethod.ReplyCount: 'Reply Count',
											ThreadSortingMethod.OPTime: 'Creation Date'
										}.entries.map((entry) => CupertinoActionSheetAction(
											child: Text(entry.value, style: TextStyle(
												fontWeight: entry.key == settings.catalogSortingMethod ? FontWeight.bold : null
											)),
											onPressed: () {
												if (settings.catalogSortingMethod == entry.key) {
													settings.reverseCatalogSorting = !settings.reverseCatalogSorting;
												}
												else {
													settings.reverseCatalogSorting = false;
													settings.catalogSortingMethod = entry.key;
												}
												Navigator.of(context, rootNavigator: true).pop();
											}
										)).toList(),
										cancelButton: CupertinoActionSheetAction(
											child: const Text('Cancel'),
											onPressed: () => Navigator.of(context, rootNavigator: true).pop()
										)
									)
								);
							}
						),
						CupertinoButton(
							padding: EdgeInsets.zero,
							child: Icon(Icons.create),
							onPressed: () {
								setState(() {
									showReplyBox = !showReplyBox;
								});
							}
						)
					]
				)
			),
			child: Column(
				children: [
					Flexible(
						child: Stack(
							fit: StackFit.expand,
							children: [
								RefreshableList<Thread>(
									controller: _listController,
									listUpdater: () => site.getCatalog(board.name).then((list) {
										final now = DateTime.now();
										if (settings.hideOldStickiedThreads) {
											list = list.where((thread) {
												return !thread.isSticky || now.difference(thread.time).compareTo(_OLD_THREAD_THRESHOLD).isNegative;
											}).toList();
										}
										if (settings.catalogSortingMethod == ThreadSortingMethod.ReplyCount) {
											list.sort((a, b) => b.replyCount.compareTo(a.replyCount));
										}
										else if (settings.catalogSortingMethod == ThreadSortingMethod.OPTime) {
											list.sort((a, b) => b.id.compareTo(a.id));
										}
										return settings.reverseCatalogSorting ? list.reversed.toList() : list;
									}),
									id: '/${board.name}/ ${settings.catalogSortingMethod} ${settings.reverseCatalogSorting}',
									itemBuilder: (context, thread) {
										return GestureDetector(
											child: ThreadRow(
												thread: thread,
												isSelected: thread.identifier == widget.selectedThread,
												semanticParentIds: [-1],
												onThumbnailTap: (initialAttachment) {
													final attachments = _listController.items.where((_) => _.attachment != null).map((_) => _.attachment!).toList();
													showGallery(
														context: context,
														attachments: attachments,
														initialAttachment: attachments.firstWhere((a) => a.id == initialAttachment.id),
														onChange: (attachment) {
															_listController.animateTo((p) => p.attachment?.id == attachment.id, alignment: 0.5);
														},
														semanticParentIds: [-1]
													);
												}
											),
											onTap: () {
												if (widget.onThreadSelected != null) {
													widget.onThreadSelected!(thread.identifier);
												}
												else {
													Navigator.of(context).push(FullWidthCupertinoPageRoute(builder: (ctx) => ThreadPage(thread: thread.identifier)));
												}
											}
										);
									},
									filterHint: 'Search in board'
								),
								StreamBuilder(
									stream: _listController.slowScrollUpdates,
									builder: (context, _) => (_listController.firstVisibleIndex <= 0) ? Container() : SafeArea(
										child: Align(
											alignment: Alignment.bottomRight,
											child: GestureDetector(
												child: Container(
													decoration: BoxDecoration(
														color: CupertinoTheme.of(context).primaryColor.withBrightness(0.6),
														borderRadius: const BorderRadius.all(Radius.circular(8))
													),
													constraints: BoxConstraints(
														minWidth: 36 * MediaQuery.of(context).textScaleFactor
													),
													padding: const EdgeInsets.all(8),
													margin: const EdgeInsets.only(bottom: 16, right: 16),
													child: Text(
														_listController.firstVisibleIndex.toString(),
														textAlign: TextAlign.center,
														style: TextStyle(
															color: CupertinoTheme.of(context).scaffoldBackgroundColor
														)
													)
												),
												onTap: () => _listController.animateTo((f) => true, alignment: 0.0)
											)
										)
									)
								)
							]
						)
					),
					ReplyBox(
						board: board.name,
						visible: showReplyBox,
						onReplyPosted: (receipt) {
							final persistentState = context.read<Persistence>().getThreadState(ThreadIdentifier(board: board.name, id: receipt.id));
							persistentState.savedTime = DateTime.now();
							persistentState.save();
							setState(() {
								showReplyBox = false;
							});
							widget.onThreadSelected?.call(ThreadIdentifier(board: board.name, id: receipt.id));
						},
						onRequestFocus: () {
							setState(() {
								showReplyBox = true;
							});
						}
					)
				]
			)
		);
	}
}