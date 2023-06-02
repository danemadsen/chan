import 'dart:async';
import 'dart:math';

import 'package:chan/models/parent_and_child.dart';
import 'package:chan/services/filtering.dart';
import 'package:chan/services/settings.dart';
import 'package:chan/services/util.dart';
import 'package:chan/util.dart';
import 'package:chan/widgets/cupertino_dialog.dart';
import 'package:chan/widgets/timed_rebuilder.dart';
import 'package:chan/widgets/util.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';
import 'package:rxdart/rxdart.dart';

const double _overscrollTriggerThreshold = 100;
const _treeAnimationDuration = Duration(milliseconds: 250);

class ItemNotFoundException implements Exception {
	final String message;
	const ItemNotFoundException(this.message);
	@override
	String toString() => 'Item not found: $message';
}

class FilterAlternative {
	final String name;
	final void Function(String) handler;
	final bool suggestWhenFilterEmpty;

	const FilterAlternative({
		required this.name,
		required this.handler,
		this.suggestWhenFilterEmpty = false
	});
}

class SliverDontRebuildChildBuilderDelegate<T> extends SliverChildBuilderDelegate {
	final List<T>? list;
	final String? id;
	final void Function(int, int)? _didFinishLayout;
	final bool Function(T) shouldIgnoreForHeightEstimation;
	final NullableIndexedWidgetBuilder? separatorBuilder;

	const SliverDontRebuildChildBuilderDelegate(
    super.builder, {
		required this.list,
		this.id,
    super.findChildIndexCallback,
    super.childCount,
    super.addAutomaticKeepAlives,
    super.addRepaintBoundaries,
    super.addSemanticIndexes,
    super.semanticIndexCallback,
    super.semanticIndexOffset,
		void Function(int, int)? didFinishLayout,
		required this.shouldIgnoreForHeightEstimation,
		this.separatorBuilder
  }) : _didFinishLayout = didFinishLayout;

	@override
	void didFinishLayout(int firstIndex, int lastIndex) {
		_didFinishLayout?.call(firstIndex, lastIndex);
	}

	@override
	double? estimateMaxScrollOffset(
    int firstIndex,
    int lastIndex,
    double leadingScrollOffset,
    double trailingScrollOffset,
  ) {
		final items = list;
		if (items == null) {
			return null;
		}
		int remainingCount = 0;
		if (separatorBuilder != null) {
			if (lastIndex == (2 * items.length) - 1) {
				return trailingScrollOffset;
			}
			for (int i = lastIndex ~/ 2; i < items.length; i++) {
				if (!shouldIgnoreForHeightEstimation(items[i])) {
					remainingCount++;
				}
			}
		}
		else {
			if (lastIndex == items.length - 1) {
				return trailingScrollOffset;
			}
			for (int i = lastIndex; i < items.length; i++) {
				if (!shouldIgnoreForHeightEstimation(items[i])) {
					remainingCount++;
				}
			}
		}
		int totalCount = 0;
		if (separatorBuilder != null) {
			for (int i = 0; i <= min(items.length - 1, lastIndex ~/ 2); i++) {
				if (!shouldIgnoreForHeightEstimation(items[i])) {
					totalCount++;
				}
			}
		}
		else {
			for (int i = 0; i <= lastIndex; i++) {
				if (!shouldIgnoreForHeightEstimation(items[i])) {
					totalCount++;
				}
			}
		}
		final double averageExtent = trailingScrollOffset / totalCount;
    return trailingScrollOffset + averageExtent * remainingCount;
	}

	@override
	Widget? build(BuildContext context, int index) {
		if (index < 0 || (childCount != null && index >= childCount!)) {
      return null;
    }
		if (separatorBuilder != null) {
			final childIndex = index ~/ 2;
			if (index.isEven) {
				return super.build(context, childIndex);
			}
			else {
				return separatorBuilder!(context, childIndex);
			}
		}
		else {
			return super.build(context, index);
		}
	}

	@override
	bool shouldRebuild(SliverDontRebuildChildBuilderDelegate oldDelegate) => !listEquals(list, oldDelegate.list) || id != oldDelegate.id;
}

class SliverGridRegularTileLayoutWithCacheTrickery extends SliverGridRegularTileLayout {
	const SliverGridRegularTileLayoutWithCacheTrickery({
    required super.crossAxisCount,
    required super.mainAxisStride,
    required super.crossAxisStride,
    required super.childMainAxisExtent,
    required super.childCrossAxisExtent,
    required super.reverseCrossAxis,
  });

  @override
  int getMinChildIndexForScrollOffset(double scrollOffset) {
    return mainAxisStride > precisionErrorTolerance ? (crossAxisCount * (scrollOffset / mainAxisStride)).floor() : 0;
  }

  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset) {
    if (mainAxisStride > 0.0) {
      final double mainAxisCount = scrollOffset / mainAxisStride;
      return max(0, (crossAxisCount * mainAxisCount).ceil() - 1);
    }
    return 0;
  }
}

class SliverGridDelegateWithMaxCrossAxisExtentWithCacheTrickery extends SliverGridDelegateWithMaxCrossAxisExtent {
	const SliverGridDelegateWithMaxCrossAxisExtentWithCacheTrickery({
    required super.maxCrossAxisExtent,
    super.mainAxisSpacing = 0.0,
    super.crossAxisSpacing = 0.0,
    super.childAspectRatio = 1.0,
    super.mainAxisExtent,
  });

	@override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    int crossAxisCount = (constraints.crossAxisExtent / (maxCrossAxisExtent + crossAxisSpacing)).ceil();
    // Ensure a minimum count of 1, can be zero and result in an infinite extent
    // below when the window size is 0.
    crossAxisCount = max(1, crossAxisCount);
    final double usableCrossAxisExtent = max(
      0.0,
      constraints.crossAxisExtent - crossAxisSpacing * (crossAxisCount - 1),
    );
    final double childCrossAxisExtent = usableCrossAxisExtent / crossAxisCount;
    final double childMainAxisExtent = mainAxisExtent ?? childCrossAxisExtent / childAspectRatio;
    return SliverGridRegularTileLayoutWithCacheTrickery(
      crossAxisCount: crossAxisCount,
      mainAxisStride: childMainAxisExtent + mainAxisSpacing,
      crossAxisStride: childCrossAxisExtent + crossAxisSpacing,
      childMainAxisExtent: childMainAxisExtent,
      childCrossAxisExtent: childCrossAxisExtent,
      reverseCrossAxis: axisDirectionIsReversed(constraints.crossAxisDirection),
    );
  }
}

class _TreeTooDeepException implements Exception {
	const _TreeTooDeepException();
}

class _TreeNode<T extends Object> {
	final T item;
	final int id;
	final bool hasOmittedReplies;
	final List<_TreeNode<T>> children;
	final List<int> stubChildIds;
	final List<_TreeNode<T>> parents;

	_TreeNode(this.item, this.id, this.hasOmittedReplies) : children = [], stubChildIds = [], parents = [];

	bool find(int needle) {
		if (needle == id) {
			return true;
		}
		for (final parent in parents) {
			if (parent.find(needle)) {
				return true;
			}
		}
		return false;
	}

	@override
	String toString() => '_TreeNode<$T>(item: $item, id: $id, # children: ${children.length}, # parents: ${parents.length}';

	@override
	bool operator == (Object o) => (o is _TreeNode<T>) && (o.item == item);

	@override
	int get hashCode => item.hashCode;
}

class RefreshableListItem<T extends Object> {
	final T item;
	final bool representsUnknownStubChildren;
	final List<ParentAndChildIdentifier> representsKnownStubChildren;
	final bool highlighted;
	final bool pinned;
	bool filterCollapsed;
	final String? filterReason;
	final int id;
	final List<int> parentIds;
	final Set<int> treeDescendantIds;
	final int? _depth;
	final _RefreshableTreeItemsCacheKey _key;

	RefreshableListItem({
		required this.item,
		this.highlighted = false,
		this.pinned = false,
		this.filterCollapsed = false,
		this.filterReason,
		required this.id,
		this.parentIds = const [],
		Set<int>? treeDescendantIds,
		this.representsUnknownStubChildren = false,
		this.representsKnownStubChildren = const [],
		int? depth
	}) : treeDescendantIds = treeDescendantIds ?? {}, _depth = depth, _key = _RefreshableTreeItemsCacheKey(parentIds, id, representsUnknownStubChildren || representsKnownStubChildren.isNotEmpty);

	@override
	String toString() => 'RefreshableListItem<$T>(item: $item, id: $id, representsKnownStubChildren: $representsKnownStubChildren, treeDescendantIds: $treeDescendantIds)';

	@override
	bool operator == (Object other) => (other is RefreshableListItem<T>) &&
		(other.item == item) &&
		(other.id == id) &&
		(other.representsUnknownStubChildren == representsUnknownStubChildren) &&
		listEquals(other.representsKnownStubChildren, representsKnownStubChildren) &&
		(other.highlighted == highlighted) &&
		(other.pinned == pinned) &&
		(other.filterCollapsed == filterCollapsed) &&
		(other.filterReason == filterReason) &&
		listEquals(other.parentIds, parentIds) &&
		setEquals(other.treeDescendantIds, treeDescendantIds) &&
		(other._depth == _depth);

	@override
	int get hashCode => Object.hash(item, representsUnknownStubChildren, representsKnownStubChildren.length, highlighted, pinned, filterCollapsed, filterReason, parentIds.length, treeDescendantIds.length, _depth);

	RefreshableListItem<T> copyWith({
		List<int>? parentIds,
		bool? representsUnknownStubChildren,
		List<ParentAndChildIdentifier>? representsKnownStubChildren,
		int? depth,
	}) => RefreshableListItem(
		item: item,
		id: id,
		highlighted: highlighted,
		pinned: pinned,
		filterCollapsed: filterCollapsed,
		filterReason: filterReason,
		parentIds: parentIds ?? this.parentIds,
		treeDescendantIds: treeDescendantIds,
		representsUnknownStubChildren: representsUnknownStubChildren ?? this.representsUnknownStubChildren,
		representsKnownStubChildren: representsKnownStubChildren ?? this.representsKnownStubChildren,
		depth: depth,
	);

	int get depth {
		if (_depth != null) {
			return _depth!;
		}
		if (representsStubChildren) {
			return parentIds.length + 1;
		}
		return parentIds.length;
	}

	bool get representsStubChildren => representsUnknownStubChildren || representsKnownStubChildren.isNotEmpty;
}

class RefreshableTreeAdapter<T extends Object> {
	final int Function(T item) getId;
	final Iterable<int> Function(T item) getParentIds;
	final bool Function(T item) getHasOmittedReplies;
	final Future<List<T>> Function(List<T> currentList, List<ParentAndChildIdentifier> stubIds) updateWithStubItems;
	final Widget Function(Widget, List<int>) wrapTreeChild;
	final int opId;
	final double Function(T item, double width) estimateHeight;
	final bool Function(T item) getIsStub;
	final bool initiallyCollapseSecondLevelReplies;
	final bool collapsedItemsShowBody;

	const RefreshableTreeAdapter({
		required this.getId,
		required this.getParentIds,
		required this.getHasOmittedReplies,
		required this.updateWithStubItems,
		required this.opId,
		required this.wrapTreeChild,
		required this.estimateHeight,
		required this.getIsStub,
		required this.initiallyCollapseSecondLevelReplies,
		required this.collapsedItemsShowBody
	});
}

enum TreeItemCollapseType {
	collapsed,
	childCollapsed,
	mutuallyCollapsed,
	mutuallyChildCollapsed,
	topLevelCollapsed;
}

extension Convenience on TreeItemCollapseType? {
	bool get isDuplicate {
		switch (this) {
			case TreeItemCollapseType.mutuallyCollapsed:
			case TreeItemCollapseType.mutuallyChildCollapsed:
				return true;
			default:
				return false;
		}
	}

	bool get isHidden {
		switch (this) {
			case TreeItemCollapseType.childCollapsed:
			case TreeItemCollapseType.mutuallyChildCollapsed:
				return true;
			default:
				return false;
		}
	}
}

class _RefreshableTreeItemsCacheKey {
	final List<int> parentIds;
	final int? thisId;
	final bool representsStubChildren;
	final String _cacheKey;

	_RefreshableTreeItemsCacheKey(this.parentIds, this.thisId, this.representsStubChildren) :
		_cacheKey = '${parentIds.join(',')},$thisId,$representsStubChildren';

	@override
	bool operator ==(Object other) =>
		other is _RefreshableTreeItemsCacheKey &&
		other._cacheKey == _cacheKey;
	
	@override
	int get hashCode => _cacheKey.hashCode;
}

class _RefreshableTreeItems<T extends Object> extends ChangeNotifier {
	final List<List<int>> manuallyCollapsedItems;
	final List<List<int>> automaticallyCollapsedItems;
	final Set<int> automaticallyCollapsedTopLevelItems;
	final Map<int, int> defaultPrimarySubtreeParents = {};
	final Map<int, int> primarySubtreeParents;
	final void Function(List<List<int>>, Map<int, int>)? onManuallyCollapsedItemsChanged;
	final ValueChanged<List<int>>? onAutomaticallyCollapsedItemExpanded;
	final ValueChanged<int>? onAutomaticallyCollapsedTopLevelItemExpanded;
	final void Function(RefreshableListItem<T> item, bool looseEquality)? onCollapseOrExpand;
	final Set<List<int>> loadingOmittedItems = {};
	final Map<_RefreshableTreeItemsCacheKey, TreeItemCollapseType?> _cache = {};

	_RefreshableTreeItems({
		required this.manuallyCollapsedItems,
		required this.automaticallyCollapsedItems,
		required this.automaticallyCollapsedTopLevelItems,
		required this.primarySubtreeParents,
		required this.onAutomaticallyCollapsedItemExpanded,
		required this.onAutomaticallyCollapsedTopLevelItemExpanded,
		required this.onCollapseOrExpand,
		required this.onManuallyCollapsedItemsChanged
	});

	TreeItemCollapseType? isItemHidden(_RefreshableTreeItemsCacheKey key) {
		return _cache.putIfAbsent(key, () {
			// Need to check all parent prefixes
			for (int d = 0; d < key.parentIds.length; d++) {
				final primaryParent = primarySubtreeParents[key.parentIds[d]] ?? defaultPrimarySubtreeParents[key.parentIds[d]];
				final theParentId = d == 0 ? -1 : key.parentIds[d - 1];
				if (primaryParent != null && primaryParent != theParentId) {
					return TreeItemCollapseType.mutuallyChildCollapsed;
				}
			}
			if (key.parentIds.isNotEmpty) {
				if (automaticallyCollapsedTopLevelItems.contains(key.parentIds.first)) {
					return TreeItemCollapseType.childCollapsed;
				}
			}
			// By iterating reversed it will properly handle collapses within collapses
			for (final collapsed in manuallyCollapsedItems.reversed.followedBy(automaticallyCollapsedItems)) {
				if (collapsed.length > key.parentIds.length + 1) {
					continue;
				}
				bool keepGoing = true;
				for (int i = 0; i < collapsed.length - 1 && keepGoing; i++) {
					keepGoing = collapsed[i] == key.parentIds[i];
				}
				if (!keepGoing) {
					continue;
				}
				if (collapsed.length == key.parentIds.length + 1) {
					if (collapsed.last == key.thisId) {
						return TreeItemCollapseType.collapsed;
					}
					continue;
				}
				if (collapsed.last == key.parentIds[collapsed.length - 1]) {
					return TreeItemCollapseType.childCollapsed;
				}
			}
			if (key.parentIds.isEmpty && automaticallyCollapsedTopLevelItems.contains(key.thisId)) {
				if (key.representsStubChildren) {
					return TreeItemCollapseType.childCollapsed;
				}
				else {
					return TreeItemCollapseType.topLevelCollapsed;
				}
			}
			final personalPrimarySubtreeParent = primarySubtreeParents[key.thisId] ?? defaultPrimarySubtreeParents[key.thisId];
			if (personalPrimarySubtreeParent != null && personalPrimarySubtreeParent != (key.parentIds.tryLast ?? -1)) {
				if (key.representsStubChildren) {
					return TreeItemCollapseType.mutuallyChildCollapsed;
				}
				else {
					return TreeItemCollapseType.mutuallyCollapsed;
				}
			}
			return null;
		});
	}

  bool isItemLoadingOmittedItems(List<int> parentIds, int? thisId) {
		// By iterating reversed it will properly handle collapses within collapses
		for (final loading in loadingOmittedItems) {
			if (loading.length != parentIds.length + 1) {
				continue;
			}
			bool keepGoing = true;
			for (int i = 0; i < loading.length - 1 && keepGoing; i++) {
				keepGoing = loading[i] == parentIds[i];
			}
			if (keepGoing && loading.last == thisId) {
				return true;
			}
		}
		return false;
	}

	void itemLoadingOmittedItemsStarted(List<int> parentIds, int thisId) {
		loadingOmittedItems.add([
			...parentIds,
			thisId
		]);
		notifyListeners();
	}

	void itemLoadingOmittedItemsEnded(RefreshableListItem<T> item) {
		final x = [
			...item.parentIds,
			item.id
		];
		loadingOmittedItems.removeWhere((w) => listEquals(w, x));
		notifyListeners();
		onCollapseOrExpand?.call(item, true);
	}

	void hideItem(RefreshableListItem<T> item) {
		manuallyCollapsedItems.add([
			...item.parentIds,
			item.id
		]);
		_cache.removeWhere((key, value) => key.thisId == item.id || key.parentIds.contains(item.id));
		onManuallyCollapsedItemsChanged?.call(manuallyCollapsedItems, primarySubtreeParents);
		onCollapseOrExpand?.call(item, false);
		notifyListeners();
	}

	void unhideItem(RefreshableListItem<T> item) {
		final x = [
			...item.parentIds,
			item.id
		];
		_cache.removeWhere((key, value) => key.thisId == item.id || key.parentIds.contains(item.id));
		final manuallyCollapsedItemsLengthBefore = manuallyCollapsedItems.length;
		manuallyCollapsedItems.removeWhere((w) => listEquals(w, x));
		if (manuallyCollapsedItemsLengthBefore != manuallyCollapsedItems.length) {
			onManuallyCollapsedItemsChanged?.call(manuallyCollapsedItems, primarySubtreeParents);
		}
		final automaticallyCollapsedItemsLengthBefore = automaticallyCollapsedItems.length;
		automaticallyCollapsedItems.removeWhere((w) => listEquals(w, x));
		if (automaticallyCollapsedItemsLengthBefore != automaticallyCollapsedItems.length) {
			onAutomaticallyCollapsedItemExpanded?.call(x);
		}
		if (automaticallyCollapsedTopLevelItems.remove(item.id)) {
			onAutomaticallyCollapsedTopLevelItemExpanded?.call(item.id);
		}
		onCollapseOrExpand?.call(item, false);
		notifyListeners();
	}

	void swapSubtreeTo(RefreshableListItem<T> item) {
		primarySubtreeParents[item.id] = item.parentIds.tryLast ?? -1;
		_cache.removeWhere((key, value) => key.thisId == item.id || key.parentIds.contains(item.id));
		onManuallyCollapsedItemsChanged?.call(manuallyCollapsedItems, primarySubtreeParents);
		onCollapseOrExpand?.call(item, false);
		notifyListeners();
	}
}

class RefreshableList<T extends Object> extends StatefulWidget {
	final Widget Function(BuildContext context, T value) itemBuilder;
	final Widget Function({
		required BuildContext context,
		required T? value,
		required Set<int> collapsedChildIds,
		required bool loading,
		required double? peekContentHeight,
		required List<ParentAndChildIdentifier>? stubChildIds
	})? collapsedItemBuilder;
	final List<T>? initialList;
	final Future<List<T>?> Function() listUpdater;
	final Future<List<T>> Function(T after)? listExtender;
	final String id;
	final RefreshableListController<T>? controller;
	final String? filterHint;
	final Widget Function(BuildContext context, T value, VoidCallback resetPage, String filter)? filteredItemBuilder;
	final Duration? autoUpdateDuration;
	final Map<Type, Widget Function(BuildContext, VoidCallback)> remedies;
	final bool disableUpdates;
	final bool disableBottomUpdates;
	final Widget? footer;
	final SliverGridDelegate? gridDelegate;
	final String? initialFilter;
	final ValueChanged<String?>? onFilterChanged;
	final bool allowReordering;
	final ValueChanged<T>? onWantAutosave;
	final Filterable Function(T)? filterableAdapter;
	final FilterAlternative? filterAlternative;
	final bool useTree;
	final RefreshableTreeAdapter<T>? treeAdapter;
	final List<Comparator<T>> sortMethods;
	final bool reverseSort;
	final List<List<int>>? initialCollapsedItems;
	final Map<int, int>? initialPrimarySubtreeParents;
	final void Function(List<List<int>>, Map<int, int>)? onCollapsedItemsChanged;
	final Duration minUpdateDuration;
	final Listenable? updateAnimation;
	final bool canTapFooter;
	final double minCacheExtent;

	const RefreshableList({
		required this.itemBuilder,
		required this.listUpdater,
		this.listExtender,
		required this.id,
		this.controller,
		this.filterHint,
		this.filteredItemBuilder,
		this.autoUpdateDuration,
		this.remedies = const {},
		this.initialList,
		this.disableUpdates = false,
		this.disableBottomUpdates = false,
		this.gridDelegate,
		this.footer,
		this.initialFilter,
		this.onFilterChanged,
		this.allowReordering = false,
		this.onWantAutosave,
		required this.filterableAdapter,
		this.filterAlternative,
		this.useTree = false,
		this.treeAdapter,
		this.collapsedItemBuilder,
		this.sortMethods = const [],
		this.reverseSort = false,
		this.initialCollapsedItems,
		this.initialPrimarySubtreeParents,
		this.onCollapsedItemsChanged,
		this.minUpdateDuration = const Duration(milliseconds: 500),
		this.updateAnimation,
		this.canTapFooter = true,
		this.minCacheExtent = 0,
		Key? key
	}) : super(key: key);

	@override
	createState() => RefreshableListState<T>();
}

class RefreshableListState<T extends Object> extends State<RefreshableList<T>> with TickerProviderStateMixin {
	List<T>? originalList;
	List<T>? sortedList;
	String? errorMessage;
	Type? errorType;
	SearchFilter? _searchFilter;
	late final ValueNotifier<bool> updatingNow;
	late final TextEditingController _searchController;
	late final FocusNode _searchFocusNode;
	bool get searchHasFocus => _searchFocusNode.hasFocus;
	DateTime? lastUpdateTime;
	DateTime? nextUpdateTime;
	Timer? autoUpdateTimer;
	GlobalKey _scrollViewKey = GlobalKey(debugLabel: 'RefreshableListState._scrollViewKey');
	GlobalKey _sliverListKey = GlobalKey(debugLabel: 'RefreshableListState._sliverListKey');
	GlobalKey _footerKey = GlobalKey(debugLabel: 'RefreshableListState._footerKey');
	int _pointerDownCount = 0;
	bool _showFilteredValues = false;
	bool _searchTapped = false;
	bool _overscrollEndingNow = false;
	late final AnimationController _footerShakeAnimation;
	DateTime _lastPointerUpTime = DateTime(2000);
	final List<List<int>> _automaticallyCollapsedItems = [];
	final List<List<int>> _overrideExpandAutomaticallyCollapsedItems = [];
	final Set<int> _automaticallyCollapsedTopLevelItems = {};
	final Set<int> _overrideExpandAutomaticallyCollapsedTopLevelItems = {};
	List<RefreshableListItem<T>> filteredValues = [];
	late _RefreshableTreeItems _refreshableTreeItems;
	int forceRebuildId = 0;
	Timer? _trailingUpdateAnimationTimer;
	bool _treeBuildingFailed = false;

	bool get useTree => widget.useTree && !_treeBuildingFailed;
	bool get treeBuildingFailed => _treeBuildingFailed;

	@override
	void initState() {
		super.initState();
		updatingNow = ValueNotifier(false);
		_searchController = TextEditingController();
		_searchFocusNode = FocusNode();
		 _footerShakeAnimation = AnimationController(vsync: this, duration: const Duration(milliseconds: 250));
		if (widget.initialFilter != null) {
			_searchFilter = SearchFilter(widget.initialFilter!.toLowerCase());
			_searchTapped = true;
			_searchController.text = widget.initialFilter!;
		}
		widget.controller?.attach(this);
		widget.controller?.newContentId(widget.id);
		originalList = widget.initialList?.toList();
		if (originalList != null) {
			sortedList = originalList!.toList();
			_sortList();
		}
		if (!widget.disableUpdates) {
			update();
			resetTimer();
		}
		_refreshableTreeItems = _RefreshableTreeItems<T>(
			manuallyCollapsedItems: widget.initialCollapsedItems?.toList() ?? [],
			automaticallyCollapsedItems: _automaticallyCollapsedItems,
			automaticallyCollapsedTopLevelItems: _automaticallyCollapsedTopLevelItems,
			primarySubtreeParents: Map.from(widget.initialPrimarySubtreeParents ?? {}),
			onAutomaticallyCollapsedItemExpanded: _onAutomaticallyCollapsedItemExpanded,
			onAutomaticallyCollapsedTopLevelItemExpanded: _onAutomaticallyCollapsedTopLevelItemExpanded,
			onCollapseOrExpand: _onTreeCollapseOrExpand,
			onManuallyCollapsedItemsChanged: widget.onCollapsedItemsChanged,
		);
		widget.updateAnimation?.addListener(_onUpdateAnimation);
	}

	@override
	void didUpdateWidget(RefreshableList<T> oldWidget) {
		super.didUpdateWidget(oldWidget);
		if (oldWidget.updateAnimation != widget.updateAnimation) {
			oldWidget.updateAnimation?.removeListener(_onUpdateAnimation);
			widget.updateAnimation?.addListener(_onUpdateAnimation);
		}
		if (oldWidget.id != widget.id) {
			autoUpdateTimer?.cancel();
			autoUpdateTimer = null;
			widget.controller?.newContentId(widget.id);
			_scrollViewKey = GlobalKey(debugLabel: 'RefreshableListState._scrollViewKey');
			_sliverListKey = GlobalKey(debugLabel: 'RefreshableListState._sliverListKey');
			_footerKey = GlobalKey(debugLabel: 'RefreshableListState._footerKey');
			closeSearch();
			originalList = widget.initialList;
			sortedList = null;
			errorMessage = null;
			errorType = null;
			lastUpdateTime = null;
			_automaticallyCollapsedItems.clear();
			_overrideExpandAutomaticallyCollapsedItems.clear();
			_automaticallyCollapsedTopLevelItems.clear();
			_overrideExpandAutomaticallyCollapsedTopLevelItems.clear();
			_refreshableTreeItems.dispose();
			_refreshableTreeItems = _RefreshableTreeItems<T>(
				manuallyCollapsedItems: widget.initialCollapsedItems?.toList() ?? [],
				automaticallyCollapsedItems: _automaticallyCollapsedItems,
				automaticallyCollapsedTopLevelItems: _automaticallyCollapsedTopLevelItems,
				primarySubtreeParents: Map.from(widget.initialPrimarySubtreeParents ?? {}),
				onAutomaticallyCollapsedItemExpanded: _onAutomaticallyCollapsedItemExpanded,
				onAutomaticallyCollapsedTopLevelItemExpanded: _onAutomaticallyCollapsedTopLevelItemExpanded,
				onCollapseOrExpand: _onTreeCollapseOrExpand,
				onManuallyCollapsedItemsChanged: widget.onCollapsedItemsChanged
			);
			if (!widget.disableUpdates) {
				update();
			}
		}
		else if (oldWidget.disableUpdates != widget.disableUpdates) {
			autoUpdateTimer?.cancel();
			autoUpdateTimer = null;
			if (!widget.disableUpdates) {
				update();
				resetTimer();
			}
		}
		else if ((widget.disableUpdates || originalList == null) && !listEquals(oldWidget.initialList, widget.initialList)) {
			originalList = widget.initialList;
			sortedList = null;
			if (originalList != null) {
				_sortList();
			}
		}
		if ((!listEquals(widget.sortMethods, oldWidget.sortMethods) ||
		     widget.reverseSort != oldWidget.reverseSort ||
				 sortedList == null) && originalList != null) {
			sortedList = originalList!.toList();
			_sortList();
		}
		if (!widget.disableUpdates && !oldWidget.disableUpdates &&
		    widget.autoUpdateDuration != oldWidget.autoUpdateDuration) {
			if (nextUpdateTime?.isAfter(DateTime.now().add(widget.autoUpdateDuration ?? Duration.zero)) ?? true) {
				// next update is scheduled too late or is scheduled at all if we now have auto-update off
				resetTimer();
			}
		}
	}

	@override
	void dispose() {
		super.dispose();
		widget.updateAnimation?.removeListener(_onUpdateAnimation);
		autoUpdateTimer?.cancel();
		_searchController.dispose();
		_searchFocusNode.dispose();
		_footerShakeAnimation.dispose();
		_refreshableTreeItems.dispose();
		updatingNow.dispose();
	}

	void _sortList() {
		for (final method in widget.sortMethods) {
			mergeSort<T>(sortedList!, compare: method);
		}
		if (widget.reverseSort) {
			sortedList = sortedList!.reversed.toList();
		}
	}

	void _onAutomaticallyCollapsedItemExpanded(List<int> item) {
		_overrideExpandAutomaticallyCollapsedItems.add(item);
	}

	void _onAutomaticallyCollapsedTopLevelItemExpanded(int item) {
		_overrideExpandAutomaticallyCollapsedTopLevelItems.add(item);
	}

	Future<void> _onTreeCollapseOrExpand(RefreshableListItem<T> item, bool looseEquality) async {
		Duration total = Duration.zero;
		while (total < _treeAnimationDuration) {
			const incremental = Duration(milliseconds: 50);
			await Future.delayed(incremental);
			widget.controller?.invalidateAfter(item, looseEquality);
			widget.controller?._scrollStream.add(null);
			total += incremental;
		}
	}

	void resetTimer() {
		autoUpdateTimer?.cancel();
		if (widget.autoUpdateDuration != null) {
			autoUpdateTimer = Timer(widget.autoUpdateDuration!, update);
			nextUpdateTime = DateTime.now().add(widget.autoUpdateDuration!);
		}
		else {
			nextUpdateTime = null;
		}
	}

	void closeSearch() {
		_searchFocusNode.unfocus();
		_searchController.clear();
		setState(() {
			_searchTapped = false;
			_searchFilter = null;
		});
		WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
			widget.onFilterChanged?.call(null);
		});
	}

	void _focusSearch() {
		_searchFocusNode.requestFocus();
		_searchTapped = true;
		setState(() {});
	}

	Future<void> _loadOmittedItems(RefreshableListItem<T> value) async {
		_refreshableTreeItems.itemLoadingOmittedItemsStarted(value.parentIds, value.id);
		try {
			originalList = await widget.treeAdapter!.updateWithStubItems(originalList!, value.representsUnknownStubChildren ? [ParentAndChildIdentifier.same(value.id)] : value.representsKnownStubChildren);
			sortedList = originalList!.toList();
			_sortList();
			setState(() { });
		}
		catch (e) {
			alertError(context, e.toStringDio());
		}
		finally {
			_refreshableTreeItems.itemLoadingOmittedItemsEnded(value);
		}
	}

	void _onUpdateAnimation() {
		if (DateTime.now().difference(lastUpdateTime ?? DateTime(2000)) > const Duration(seconds: 1)) {
			update();
		}
		else {
			_trailingUpdateAnimationTimer?.cancel();
			_trailingUpdateAnimationTimer = Timer(const Duration(seconds: 1), _onUpdateAnimation);
		}
	}

	Future<void> update({bool hapticFeedback = false, bool extend = false}) async {
		if (updatingNow.value) {
			return;
		}
		final updatingWithId = widget.id;
		List<T>? newList;
		try {
			setState(() {
				errorMessage = null;
				errorType = null;
				updatingNow.value = true;
			});
			Duration minUpdateDuration = widget.minUpdateDuration;
			if (widget.controller?.scrollController?.positions.length == 1 && (widget.controller!.scrollController!.position.pixels > 0 && (widget.controller!.scrollController!.position.pixels <= widget.controller!.scrollController!.position.maxScrollExtent))) {
				minUpdateDuration *= 2;
			}
			final lastItem = widget.controller?._items.tryLast?.item;
			if (extend && widget.treeAdapter != null && ((lastItem?.representsStubChildren ?? false))) {
				_refreshableTreeItems.itemLoadingOmittedItemsStarted(lastItem!.parentIds, lastItem.id);
				try {
					newList = await widget.treeAdapter!.updateWithStubItems(originalList!, lastItem.representsUnknownStubChildren ? [ParentAndChildIdentifier.same(lastItem.id)] : lastItem.representsKnownStubChildren);
				}
				catch (e) {
					alertError(context, e.toStringDio());
				}
				finally {
					_refreshableTreeItems.itemLoadingOmittedItemsEnded(lastItem);
				}
			}
			else if (extend && widget.listExtender != null && (originalList?.isNotEmpty ?? false)) {
				final newItems = (await Future.wait([widget.listExtender!(originalList!.last), Future<List<T>?>.delayed(minUpdateDuration)])).first!;
				newList = originalList!.followedBy(newItems).toList();
			}
			else {
				newList = (await Future.wait([widget.listUpdater(), Future<List<T>?>.delayed(minUpdateDuration)])).first?.toList();
			}
			if (!mounted) return;
			if (updatingWithId != widget.id) {
				updatingNow.value = false;
				return;
			}
			resetTimer();
			lastUpdateTime = DateTime.now();
		}
		catch (e, st) {
			errorMessage = e.toStringDio();
			errorType = e.runtimeType;
			if (mounted) {
				if (widget.controller?.scrollController?.hasOnePosition ?? false) {
					final position = widget.controller!.scrollController!.position;
					if (position.extentAfter > 0) {
						showToast(
							context: context,
							message: 'Error loading ${widget.id}: $errorMessage',
							icon: CupertinoIcons.exclamationmark_triangle
						);
					}
				}
				if (widget.remedies[errorType] == null) {
					print('Error refreshing list: ${e.toStringDio()}');
					print(st);
					resetTimer();
					lastUpdateTime = DateTime.now();
				}
				else {
					nextUpdateTime = null;
				}
			}
		}
		if (widget.controller?.scrollController?.positions.length == 1 && widget.controller?.scrollController?.position.isScrollingNotifier.value == true) {
			final completer = Completer<void>();
			void listener() {
				if (widget.controller?.scrollController?.position.isScrollingNotifier.value == false) {
					completer.complete();
				}
			}
			widget.controller!.scrollController!.position.isScrollingNotifier.addListener(listener);
			await Future.any([completer.future, Future.delayed(const Duration(seconds: 3))]);
			if (!mounted) return;
			widget.controller?.scrollController?.position.isScrollingNotifier.removeListener(listener);
			if (updatingWithId != widget.id) {
				updatingNow.value = false;
				return;
			}
		}
		if (!mounted) return;
		updatingNow.value = false;
		if (mounted && (newList != null || originalList == null || errorMessage != null)) {
			if (hapticFeedback) {
				mediumHapticFeedback();
			}
			setState(() {
				originalList = newList ?? originalList;
				sortedList = originalList?.toList();
				if (sortedList != null) {
					_sortList();
				}
			});
		}
	}

	void acceptNewList(List<T> list) {
		originalList = list;
		sortedList = list.toList();
		_sortList();
		setState(() {});
	}

	Future<void> _updateWithHapticFeedback() async {
		await update(hapticFeedback: true, extend: false);
	}

	Future<void> _updateOrExtendWithHapticFeedback() async {
		await update(hapticFeedback: true, extend: true);
	}

	bool _shouldIgnoreForHeightEstimation(RefreshableListItem<T> item) {
		return _refreshableTreeItems.isItemHidden(item._key).isHidden;
	}

	Widget _itemBuilder(BuildContext context, RefreshableListItem<T> value) {
		Widget child;
		Widget? collapsed;
		bool loadingOmittedItems = false;
		if (widget.treeAdapter != null && (useTree || value.representsStubChildren)) {
			loadingOmittedItems = context.select<_RefreshableTreeItems, bool>((c) => c.isItemLoadingOmittedItems(value.parentIds, value.id));
		}
		if (_searchFilter != null && widget.filteredItemBuilder != null) {
			child = Builder(
				builder: (context) => widget.filteredItemBuilder!(context, value.item, closeSearch, _searchFilter!.text)
			);
		}
		else {
			if (value.representsStubChildren) {
				child = widget.collapsedItemBuilder?.call(
					context: context,
					value: null,
					collapsedChildIds: value.representsKnownStubChildren.map((x) => x.childId).toSet(),
					loading: loadingOmittedItems,
					peekContentHeight: null,
					stubChildIds: value.representsKnownStubChildren
				) ?? Container(
					height: 30,
					alignment: Alignment.center,
					child: Text('${value.representsKnownStubChildren.length} more replies...')
				);
			}
			else {
				child = Builder(
					builder: (context) => widget.itemBuilder(context, value.item)
				);
				collapsed = widget.collapsedItemBuilder?.call(
					context: context,
					value: value.item,
					collapsedChildIds: value.treeDescendantIds,
					loading: loadingOmittedItems,
					peekContentHeight: (widget.treeAdapter?.collapsedItemsShowBody ?? false) ? double.infinity : null,
					stubChildIds: null
				);
				if (value.filterCollapsed && collapsed != null) {
					collapsed = Opacity(
						opacity: 0.5,
						child: collapsed
					);
				}
			}
			if (widget.treeAdapter != null && useTree) {
				final isHidden = context.select<_RefreshableTreeItems, TreeItemCollapseType?>((c) => c.isItemHidden(value._key));
				if (value.parentIds.isNotEmpty && !isHidden.isHidden) {
					child = widget.treeAdapter!.wrapTreeChild(child, value.parentIds);
				}
				if (isHidden.isHidden) {
					// Avoid possible heavy build+layout cost for hidden items
					child = const SizedBox(width: double.infinity);
				}
				else if (isHidden == TreeItemCollapseType.mutuallyCollapsed ||
				         isHidden == TreeItemCollapseType.topLevelCollapsed) {
					child = widget.collapsedItemBuilder?.call(
						context: context,
						value: value.item,
						collapsedChildIds: value.treeDescendantIds,
						loading: loadingOmittedItems,
						peekContentHeight: isHidden == TreeItemCollapseType.mutuallyCollapsed ? 90 : double.infinity,
						stubChildIds: null
					) ?? Container(
						height: 30,
						alignment: Alignment.center,
						child: Text('${value.item} mutually-collapsed')
					);
				}
				else {
					child = AnimatedCrossFade(
						key: ValueKey(value),
						duration: _treeAnimationDuration,
						sizeCurve: Curves.ease,
						firstCurve: Curves.ease,
						//secondCurve: Curves.ease,
						firstChild: child,
						secondChild: (!isHidden.isHidden && !value.representsStubChildren) ? (collapsed ?? const SizedBox(
							height: 30,
							width: double.infinity,
							child: Text('Something hidden')
						)) : const SizedBox(
							height: 0,
							width: double.infinity
						),
						crossFadeState: isHidden == null ? CrossFadeState.showFirst : CrossFadeState.showSecond,
					);
				}
				child = AnimatedSize(
					duration: _treeAnimationDuration,
					alignment: Alignment.topCenter,
					curve: Curves.ease,
					child: child
				);
				child = GestureDetector(
					behavior: HitTestBehavior.translucent,
					onTap: loadingOmittedItems ? null : () async {
						if (!value.representsStubChildren) {
							if (isHidden == TreeItemCollapseType.mutuallyCollapsed) {
								context.read<_RefreshableTreeItems>().swapSubtreeTo(value);
								Future.delayed(_treeAnimationDuration, () => widget.controller?._alignToItemIfPartiallyAboveFold(value));
							}
							else if (isHidden != null) {
								context.read<_RefreshableTreeItems>().unhideItem(value);
								if (isHidden == TreeItemCollapseType.topLevelCollapsed) {
									final stubParent = widget.controller?.items.tryFirstWhere((otherItem) {
										return otherItem.item == value.item &&
												otherItem.id == value.id &&
												otherItem.parentIds == value.parentIds &&
												otherItem.representsStubChildren;
									});
									if (stubParent != null) {
										_loadOmittedItems(stubParent);
									}
								}
							}
							else if (value.treeDescendantIds.isNotEmpty || !(widget.treeAdapter?.collapsedItemsShowBody ?? false)) {
								context.read<_RefreshableTreeItems>().hideItem(value);
								widget.controller?._alignToItemIfPartiallyAboveFold(value);
							}
						}
						else {
							_loadOmittedItems(value);
						}
					},
					child: child
				);
			}
			else if (widget.treeAdapter != null && value.representsStubChildren) {
				child = GestureDetector(
					behavior: HitTestBehavior.translucent,
					onTap: loadingOmittedItems ? null : () => _loadOmittedItems(value),
					child: child
				);
			}
		}
		if (value.highlighted) {
			child = ClipRect(
				child: ColorFiltered(
					colorFilter: ColorFilter.mode(context.select<EffectiveSettings, Color>((s) => s.theme.secondaryColor).withOpacity(0.2), BlendMode.srcOver),
					child: child
				)
			);
		}
		if (value.pinned) {
			child = ClipRect(
				child: ColorFiltered(
					colorFilter: ColorFilter.mode(context.select<EffectiveSettings, Color>((s) => s.theme.secondaryColor).withOpacity(0.05), BlendMode.srcOver),
					child: child
				)
			);
		}
		if (value.depth > 0 && useTree) {
			child = Container(
				margin: EdgeInsets.only(left: (pow(value.depth, 0.70) * 20) - 5),
				decoration: BoxDecoration(
					border: Border(left: BorderSide(
						width: 5,
						color: context.select<EffectiveSettings, Color>((s) => s.theme.secondaryColor).withMinValue(0.5).withSaturation(0.5).shiftHue(value.depth * 25).withOpacity(0.7)
					))
				),
				child: child
			);
		}
		child = KeyedSubtree(
			key: ValueKey(value),
			child: child
		);
		return child;
	}

	bool _shouldPreCollapseOnSubsequentEncounter(RefreshableListItem<T> item, _TreeNode<RefreshableListItem<T>> node) {
		final width = (context.findRenderObject() as RenderBox?)?.paintBounds.width ?? 500;
		final height = (widget.treeAdapter?.estimateHeight(item.item, width) ?? 0);
		final parentCount = widget.treeAdapter?.getParentIds(item.item).length ?? 0;
		return height > (100 * max(parentCount, 3)) || node.children.isNotEmpty;
	}

	({
		List<RefreshableListItem<T>> tree,
		List<List<int>> automaticallyCollapsed,
		Set<int> automaticallyTopLevelCollapsed
	}) _reassembleAsTree(List<RefreshableListItem<T>> linear) {
		// In case the list is not in sequential order by id
		final orphans = <int, List<_TreeNode<RefreshableListItem<T>>>>{};
		final orphanStubs = <int, List<int>>{};
		final treeMap = <int, _TreeNode<RefreshableListItem<T>>>{};
		final treeRoots = <_TreeNode<RefreshableListItem<T>>>[];

		final adapter = widget.treeAdapter;
		if (adapter == null) {
			print('Tried to reassemble a tree of $T with a null adapter');
			return (tree: linear, automaticallyCollapsed: [], automaticallyTopLevelCollapsed: {});
		}

		for (final item in linear) {
			final id = adapter.getId(item.item);
			final node = _TreeNode(item.copyWith(), id, adapter.getHasOmittedReplies(item.item));
			treeMap[id] = node;
			node.children.addAll(orphans[id] ?? []);
			orphans.remove(id);
			node.stubChildIds.addAll(orphanStubs[id] ?? []);
			orphanStubs.remove(id);
			final parentIds = adapter.getParentIds(item.item).toList();
			if (id == adapter.opId) {
				treeRoots.insert(0, node);
			}
			else if (parentIds.isEmpty || (parentIds.length == 1 && parentIds.single == adapter.opId)) {
				treeRoots.add(node);
				final op = treeMap[adapter.opId];
				if (op != null) {
					node.parents.add(op);
				}
			}
			else {
				// Will only work with sequential ids
				node.parents.addAll(parentIds.map((id) => treeMap[id]).where((p) => p != null).map((p) => p!));
			}
			if (parentIds.length > 1) {
				// Avoid multiple child subtrees in the same root tree
				// This doesn't handle orphans case, but that should only happen on Reddit,
				// which doesn't have multiple parents anyways.
				final parents = parentIds.map((id) => treeMap[id]).where((p) => p != null).map((p) => p!).toList();
				// Sort to process from shallowest to deepest
				parents.sort((a, b) => a.id.compareTo(b.id));
				int? findToDelete() {
					for (int i = 0; i < parents.length; i++) {
						for (int j = i + 1; j < parents.length; j++) {
							if (parents[j].find(parents[i].id)) {
								// child already quotes the parent
								return i;
							}
						}
					}
					return null;
				}
				int? toDelete;
				do {
					toDelete = findToDelete();
					if (toDelete != null) {
						final deleted = parents.removeAt(toDelete);
						parentIds.remove(deleted.id);
					}
				} while (toDelete != null);
			}
			if (adapter.getIsStub(item.item)) {
				for (final parentId in parentIds) {
					treeMap[parentId]?.stubChildIds.add(node.id);
					if (treeMap[parentId] == null) {
						orphanStubs.putIfAbsent(parentId, () => []).add(node.id);
					}
				}
			}
			else {
				bool foundAParent = false;
				final orphanParents = <int>[];
				for (final parentId in parentIds) {
					if (parentId == adapter.opId) {
						foundAParent = true;
						continue;
					}
					treeMap[parentId]?.children.add(node);
					if (treeMap[parentId] == null) {
						orphanParents.add(parentId);
					}
					else {
						foundAParent = true;
					}
				}
				if (!foundAParent) {
					for (final parentId in orphanParents) {
						orphans.putIfAbsent(parentId, () => []).add(node);
					}
				}
			}
		}

		final out = <RefreshableListItem<T>>[];
		final Map<int, RefreshableListItem<T>> encountered = {};
		final precollapseCache = <T, bool>{};
		final automaticallyCollapsed = <List<int>>[];
		final Set<int> automaticallyTopLevelCollapsed = {};
		Set<int> dumpNode(_TreeNode<RefreshableListItem<T>> node, List<int> parentIds, {bool addOmittedChildNode = true}) {
			if (out.length > 15000) {
				// Bail
				throw const _TreeTooDeepException();
			}
			final item = node.item.copyWith(parentIds: parentIds);
			out.add(item);
			final ids = [
				...parentIds,
				node.id
			];
			final willAddOmittedChildNode = addOmittedChildNode && (node.stubChildIds.isNotEmpty || node.hasOmittedReplies);
			if (node.parents.length > 1) {
				if (precollapseCache.putIfAbsent(node.item.item, () => _shouldPreCollapseOnSubsequentEncounter(item, node))) {
					_refreshableTreeItems.defaultPrimarySubtreeParents.putIfAbsent(node.id, () => parentIds.tryLast ?? -1);
				}
			}
			else if (adapter.initiallyCollapseSecondLevelReplies &&
			         parentIds.isEmpty &&
							 (node.parents.isEmpty || node.parents.trySingle?.id == adapter.opId) &&
							 (node.children.isNotEmpty || willAddOmittedChildNode)) {
				automaticallyTopLevelCollapsed.add(node.id);
			}
			if (item.filterCollapsed) {
				automaticallyCollapsed.add(ids);
			}
			for (final child in node.children) {
				if (child.id == node.id) {
					print('Skipping recursive child of ${node.id}');
					continue;
				}
				item.treeDescendantIds.add(child.id);
				item.treeDescendantIds.addAll(dumpNode(child, ids.toList()));
			}
			if (willAddOmittedChildNode) {
				out.add(item.copyWith(
					representsKnownStubChildren: node.stubChildIds.map((childId) => ParentAndChildIdentifier(
						parentId: node.id,
						childId: childId
					)).toList(),
					representsUnknownStubChildren: node.hasOmittedReplies
				));
				item.treeDescendantIds.addAll(node.stubChildIds);
				if (node.hasOmittedReplies) {
					item.treeDescendantIds.add(-1);
				}
			}
			encountered[node.id] = item;
			return item.treeDescendantIds;
		}
		_TreeNode<RefreshableListItem<T>>? firstRoot;
		if (treeRoots.isNotEmpty) {
			firstRoot = treeRoots.removeAt(0);
			dumpNode(firstRoot, [], addOmittedChildNode: false);
		}
		final Set<int> orphanEncountered = {};
		for (final pair in orphans.entries) {
			for (final orphan in pair.value) {
				if (encountered.containsKey(orphan.id) || orphanEncountered.contains(orphan.id)) {
					// It is seen somewhere else in the tree
					continue;
				}
				insertIntoSortedList(
					list: treeRoots,
					sortMethods: widget.sortMethods.isEmpty ? <Comparator<_TreeNode<RefreshableListItem<T>>>>[
						(a, b) => a.id.compareTo(b.id)
					] : widget.sortMethods.map((c) => (a, b) => c(a.item.item, b.item.item)).toList(),
					reverseSort: widget.reverseSort,
					item: orphan
				);
				orphanEncountered.add(orphan.id);
			}
		}
		for (final root in treeRoots) {
			if (adapter.getIsStub(root.item.item)) {
				continue;
			}
			dumpNode(root, []);
		}
		if (firstRoot != null && (firstRoot.stubChildIds.isNotEmpty || firstRoot.hasOmittedReplies)) {
			out.add(firstRoot.item.copyWith(
				parentIds: [],
				representsKnownStubChildren: firstRoot.stubChildIds.map((childId) => ParentAndChildIdentifier(
					parentId: firstRoot!.id,
					childId: childId
				)).toList(),
				representsUnknownStubChildren: firstRoot.hasOmittedReplies,
				depth: 0
			));
		}
		return (tree: out, automaticallyCollapsed: automaticallyCollapsed, automaticallyTopLevelCollapsed: automaticallyTopLevelCollapsed);
	}

	@override
	Widget build(BuildContext context) {
		widget.controller?.reportPrimaryScrollController(PrimaryScrollController.maybeOf(context));
		widget.controller?.topOffset = MediaQuery.paddingOf(context).top;
		widget.controller?.bottomOffset = MediaQuery.paddingOf(context).bottom;
		if (sortedList != null) {
			final pinnedValues = <RefreshableListItem<T>>[];
			List<RefreshableListItem<T>> values = [];
			filteredValues = <RefreshableListItem<T>>[];
			final filters = [
				if (_searchFilter != null) _searchFilter!,
				Filter.of(context)
			];
			for (final item in sortedList!) {
				bool handled = false;
				for (final filter in filters) {
					final result = widget.filterableAdapter != null ? filter.filter(widget.filterableAdapter!(item)) : null;
					if (result != null) {
						bool pinned = false;
						if (result.type.pinToTop && widget.allowReordering) {
							pinned = true;
							pinnedValues.add(RefreshableListItem(
								item: item,
								id: widget.treeAdapter?.getId(item) ?? 0,
								highlighted: result.type.highlight,
								pinned: true
							));
						}
						if (result.type.autoSave) {
							widget.onWantAutosave?.call(item);
						}
						if (result.type.hide) {
							filteredValues.add(RefreshableListItem(
								item: item,
								id: widget.treeAdapter?.getId(item) ?? 0,
								filterReason: result.reason
							));
						}
						else if (!pinned) {
							values.add(RefreshableListItem(
								item: item,
								id: widget.treeAdapter?.getId(item) ?? 0,
								highlighted: result.type.highlight,
								filterCollapsed: result.type.collapse
							));
						}
						handled = true;
						break;
					}
				}
				if (!handled) {
					values.add(RefreshableListItem(item: item, id: widget.treeAdapter?.getId(item) ?? 0));
				}
			}
			_treeBuildingFailed = false;
			values.insertAll(0, pinnedValues);
			if (widget.useTree) {
				try {
					final tree = _reassembleAsTree(values);
					values = tree.tree;
					_automaticallyCollapsedItems.clear();
					for (final collapsed in tree.automaticallyCollapsed) {
						if (!_overrideExpandAutomaticallyCollapsedItems.any((x) => listEquals(x, collapsed))) {
							_automaticallyCollapsedItems.add(collapsed);
						}
					}
					_automaticallyCollapsedTopLevelItems.clear();
					for (final id in tree.automaticallyTopLevelCollapsed) {
						if (!_overrideExpandAutomaticallyCollapsedTopLevelItems.contains(id)) {
							_automaticallyCollapsedTopLevelItems.add(id);
						}
					}
				}
				on _TreeTooDeepException {
					_treeBuildingFailed = true;
				}
			}
			else if (widget.treeAdapter != null) {
				final adapter = widget.treeAdapter!;
				RefreshableListItem<T>? stubItem;
				final items = values;
				values = [];
				for (final item in items) {
					if (adapter.getIsStub(item.item)) {
						stubItem ??= RefreshableListItem(
							item: item.item, // Arbitrary
							id: item.id, // Arbitrary
							representsKnownStubChildren: []
						);
						stubItem.representsKnownStubChildren.add(ParentAndChildIdentifier(
							parentId: adapter.getParentIds(item.item).tryFirst ?? adapter.opId,
							childId: adapter.getId(item.item)
						));
					}
					else {
						if (stubItem != null) {
							values.add(stubItem);
							stubItem = null;
						}
						values.add(item);
						if (adapter.getHasOmittedReplies(item.item)) {
							stubItem ??= RefreshableListItem(
								item: item.item, // Arbitrary
								id: item.id, // Arbitrary
								representsKnownStubChildren: []
							);
							stubItem.representsKnownStubChildren.add(ParentAndChildIdentifier(
								parentId: adapter.getId(item.item),
								childId: adapter.getId(item.item)
							));
						}
					}
				}
			}
			widget.controller?.setItems(values);
			if (filteredValues.isEmpty) {
				// Don't auto open filtered values after clearing it before
				_showFilteredValues = false;
			}
			final shakeAnimation = CurvedAnimation(
				curve: Curves.easeInOutCubic,
				parent: _footerShakeAnimation
			);
			return WillPopScope(
				onWillPop: () async {
					if (_searchTapped) {
						closeSearch();
						return false;
					}
					return true;
				},
					child: NotificationListener<ScrollNotification>(
					key: ValueKey(widget.id),
					onNotification: (notification) {
						if (updatingNow.value) {
							return false;
						}
						final bool isScrollEnd = (notification is ScrollEndNotification) || (notification is ScrollUpdateNotification && notification.dragDetails == null);
						final bool plausible = DateTime.now().difference(_lastPointerUpTime) < const Duration(milliseconds: 100);
						if (widget.controller != null && isScrollEnd && plausible) {
							if (!_overscrollEndingNow) {
								double overscroll = widget.controller!.scrollController!.position.pixels - widget.controller!.scrollController!.position.maxScrollExtent;
								if (overscroll > _overscrollTriggerThreshold && !widget.disableUpdates && !widget.disableBottomUpdates) {
									_overscrollEndingNow = true;
									lightHapticFeedback();
									_updateOrExtendWithHapticFeedback();
								}
							}
						}
						else {
							_overscrollEndingNow = false;
						}
						return false;
						// Auto update here
					},
					child: Listener(
						onPointerDown:(e) {
							_pointerDownCount++;
						},
						onPointerUp: (e) {
							_lastPointerUpTime = DateTime.now();
							_pointerDownCount--;
						},
						onPointerCancel: (e) {
							_lastPointerUpTime = DateTime.now();
							_pointerDownCount--;
						},
						onPointerPanZoomStart: (e) {
							_pointerDownCount++;
						},
						onPointerPanZoomEnd: (e) {
							_lastPointerUpTime = DateTime.now();
							_pointerDownCount--;
						},
						child: GestureDetector(
							onTapUp: (e) {
								if (widget.controller?.scrollController != null && (widget.controller!.scrollController!.position.userScrollDirection != ScrollDirection.idle) && _pointerDownCount == 0) {
									widget.controller!.scrollController!.jumpTo(widget.controller!.scrollController!.position.pixels);
								}
								widget.controller?.cancelCurrentAnimation();
								final footerBox = _footerKey.currentContext?.findRenderObject() as RenderBox?;
								final footerTop = footerBox?.localToGlobal(footerBox.paintBounds.topLeft).dy ?? double.infinity;
								if (e.globalPosition.dy > footerTop) {
									_updateOrExtendWithHapticFeedback();
								}
							},
							child: MaybeCupertinoScrollbar(
								controller: widget.controller?.scrollController,
								child: ChangeNotifierProvider.value(
									value: _refreshableTreeItems,
									child: CustomScrollView(
										key: _scrollViewKey,
										cacheExtent: max(widget.minCacheExtent, 250),
										controller: widget.controller?.scrollController,
										physics: const AlwaysScrollableScrollPhysics(),
										slivers: [
											SliverSafeArea(
												sliver: widget.disableUpdates ? const SliverToBoxAdapter(
													child: SizedBox.shrink()
												) : CupertinoSliverRefreshControl(
													onRefresh: _updateWithHapticFeedback,
													refreshTriggerPullDistance: 125
												),
												bottom: false
											),
											if ((sortedList?.isNotEmpty ?? false) && widget.filterableAdapter != null) SliverToBoxAdapter(
												child: Container(
													height: kMinInteractiveDimensionCupertino * context.select<EffectiveSettings, double>((s) => s.textScale),
													padding: const EdgeInsets.all(4),
													child: Row(
														mainAxisSize: MainAxisSize.min,
														children: [
															Expanded(
																child: Center(
																	child: CupertinoSearchTextField(
																		prefixIcon: const Padding(
																			padding: EdgeInsets.only(top: 2),
																			child: Icon(CupertinoIcons.search)
																		),
																		onTap: () {
																			setState(() {
																				_searchTapped = true;
																			});
																			widget.onFilterChanged?.call('');
																		},
																		onChanged: (searchText) {
																			setState(() {
																				_searchFilter = SearchFilter(searchText.toLowerCase());
																			});
																			widget.onFilterChanged?.call(searchText);
																		},
																		controller: _searchController,
																		enableIMEPersonalizedLearning: context.select<EffectiveSettings, bool>((s) => s.enableIMEPersonalizedLearning),
																		focusNode: _searchFocusNode,
																		placeholder: widget.filterHint,
																		smartQuotesType: SmartQuotesType.disabled,
																		smartDashesType: SmartDashesType.disabled
																	)
																),
															),
															if (_searchTapped) CupertinoButton(
																padding: const EdgeInsets.only(left: 8),
																onPressed: closeSearch,
																child: const Text('Cancel')
															)
														]
													)
												)
											),
											if (widget.filterAlternative != null &&
													((_searchFilter?.text.isNotEmpty ?? false) ||
													(_searchTapped && widget.filterAlternative!.suggestWhenFilterEmpty))) SliverToBoxAdapter(
												child: Container(
													decoration: BoxDecoration(
														border: Border(
															top: BorderSide(color: CupertinoTheme.of(context).primaryColorWithBrightness(0.2)),
															bottom: BorderSide(color: CupertinoTheme.of(context).primaryColorWithBrightness(0.2))
														)
													),
													child: CupertinoButton(
														padding: const EdgeInsets.all(16),
														onPressed: () {
															_searchFocusNode.unfocus();
															widget.filterAlternative!.handler(_searchFilter?.text ?? '');
														},
														child: Row(
															children: [
																const Icon(CupertinoIcons.search),
																const SizedBox(width: 8),
																Text('Search ${widget.filterAlternative?.name}')
															]
														)
													)
												)
											),
											if (values.isNotEmpty)
												if (widget.gridDelegate != null) SliverGrid(
													key: PageStorageKey('grid for ${widget.id}'),
													gridDelegate: widget.gridDelegate!,
													delegate: SliverDontRebuildChildBuilderDelegate(
														(context, i) => Builder(
															builder: (context) {
																widget.controller?.registerItem(i, values[i], context);
																return _itemBuilder(context, values[i]);
															}
														),
														list: values,
														id: '${_searchFilter?.text}${widget.sortMethods}$forceRebuildId',
														didFinishLayout: widget.controller?.didFinishLayout,
														childCount: values.length,
														addRepaintBoundaries: false,
														addAutomaticKeepAlives: false,
														shouldIgnoreForHeightEstimation: _shouldIgnoreForHeightEstimation
													)
												)
												else SliverList(
													key: _sliverListKey,
													delegate: SliverDontRebuildChildBuilderDelegate(
														(context, childIndex) {
															return Builder(
																key: ValueKey(values[childIndex]),
																builder: (context) {
																	widget.controller?.registerItem(childIndex, values[childIndex], context);
																	return _itemBuilder(context, values[childIndex]);
																}
															);
														},
														separatorBuilder: (context, childIndex) {
															int depth = values[childIndex].depth;
															if (childIndex < (values.length - 1)) {
																depth = min(depth, values[childIndex + 1].depth);
															}
															return Padding(
																padding: EdgeInsets.only(left: pow(depth, 0.70) * 20),
																child: Divider(
																	thickness: 1,
																	height: 0,
																	color: CupertinoTheme.of(context).primaryColorWithBrightness(0.2)
																)
															);
														},
														list: values,
														id: '${_searchFilter?.text}${widget.sortMethods}$forceRebuildId',
														childCount: values.length * 2,
														findChildIndexCallback: (key) {
															if (key is ValueKey) {
																final idx = values.indexOf(key.value) * 2;
																if (idx >= 0) {
																	return idx;
																}
															}
															return null;
														},
														shouldIgnoreForHeightEstimation: _shouldIgnoreForHeightEstimation,
														didFinishLayout: (startIndex, endIndex) {
															widget.controller?.didFinishLayout.call((startIndex / 2).ceil(), (endIndex / 2).floor());
														},
														addAutomaticKeepAlives: false,
														addRepaintBoundaries: false,
													)
												),
											if (values.isEmpty)
												const SliverToBoxAdapter(
														child: SizedBox(
															height: 100,
															child: Center(
																child: Text('Nothing to see here')
															)
														)
													),
											if (filteredValues.isNotEmpty) ...[
												SliverToBoxAdapter(
													child: GestureDetector(
														onTap: () {
															setState(() {
																_showFilteredValues = !_showFilteredValues;
															});
														},
														child: SizedBox(
															height: 50,
															child: Center(
																child: Text(
																	(_showFilteredValues ? 'Showing ' : '') + describeCount(filteredValues.length, 'filtered item'),
																	style: TextStyle(
																		color: CupertinoTheme.of(context).primaryColorWithBrightness(0.4)
																	)
																)
															)
														)
													),
												),
												if (_showFilteredValues) 
													if (widget.gridDelegate != null) SliverGrid(
														key: PageStorageKey('filtered grid for ${widget.id}'),
														gridDelegate: widget.gridDelegate!,
														delegate: SliverDontRebuildChildBuilderDelegate(
															(context, i) => Stack(
																children: [
																	Builder(
																		builder: (context) => _itemBuilder(context, filteredValues[i])
																	),
																	Align(
																		alignment: Alignment.topRight,
																		child: Padding(
																			padding: const EdgeInsets.only(top: 8, right: 8),
																			child: CupertinoButton.filled(
																				padding: EdgeInsets.zero,
																				child: const Icon(CupertinoIcons.question),
																				onPressed: () {
																					showCupertinoDialog(
																						context: context,
																						barrierDismissible: true,
																						builder: (context) => CupertinoAlertDialog2(
																							title: const Text('Filter reason'),
																							content: Text(filteredValues[i].filterReason ?? 'Unknown'),
																							actions: [
																								CupertinoDialogAction2(
																									child: const Text('OK'),
																									onPressed: () => Navigator.pop(context)
																								)
																							]
																						)
																					);
																				}
																			)
																		)
																	)
																]
															),
															list: filteredValues,
															id: '$forceRebuildId',
															childCount: filteredValues.length,
															addRepaintBoundaries: false,
															addAutomaticKeepAlives: false,
															shouldIgnoreForHeightEstimation: _shouldIgnoreForHeightEstimation
														)
													)
													else SliverList(
														key: PageStorageKey('filtered list for ${widget.id}'),
														delegate: SliverDontRebuildChildBuilderDelegate(
															(context, childIndex) {
																return Stack(
																	children: [
																		Builder(
																			builder: (context) => _itemBuilder(context, filteredValues[childIndex])
																		),
																		IgnorePointer(
																			child: Align(
																				alignment: Alignment.topRight,
																				child: Container(
																					padding: const EdgeInsets.all(4),
																					color: CupertinoTheme.of(context).primaryColor,
																					child: Text('Filter reason:\n${filteredValues[childIndex].filterReason}', style: TextStyle(
																						color: CupertinoTheme.of(context).scaffoldBackgroundColor
																					))
																				)
																			)
																		)
																	]
																);
															},
															separatorBuilder: (context, childIndex) => Divider(
																thickness: 1,
																height: 0,
																color: CupertinoTheme.of(context).primaryColorWithBrightness(0.2)
															),
															list: filteredValues,
															id: '$forceRebuildId',
															childCount: filteredValues.length * 2,
															addRepaintBoundaries: false,
															addAutomaticKeepAlives: false,
															shouldIgnoreForHeightEstimation: _shouldIgnoreForHeightEstimation
														)
													)
											],
											if (widget.footer != null && widget.disableUpdates) SliverSafeArea(
												top: false,
												sliver: SliverToBoxAdapter(
													child: widget.footer
												)
											)
											else if (widget.footer != null && !widget.disableUpdates) SliverToBoxAdapter(
												child: RepaintBoundary(
													child: GestureDetector(
														behavior: HitTestBehavior.opaque,
														onTap: (!widget.canTapFooter || updatingNow.value) ? null : () {
															lightHapticFeedback();
															Future.delayed(const Duration(milliseconds: 17), () {
																widget.controller?.scrollController?.animateTo(
																	widget.controller!.scrollController!.position.maxScrollExtent,
																	duration: const Duration(milliseconds: 250),
																	curve: Curves.ease
																);
															});
															_footerShakeAnimation.forward(from: 0);
															_updateOrExtendWithHapticFeedback();
														},
														child: AnimatedBuilder(
															animation: shakeAnimation,
															builder: (context, child) => Transform.scale(
																scale: 1.0 - 0.2*sin(pi * shakeAnimation.value),
																child: child
															),
															child: widget.footer
														)
													)
												)
											)
											else if (widget.disableUpdates) const SliverSafeArea(
												top: false,
												sliver: SliverToBoxAdapter(
													child: SizedBox.shrink()
												)
											),
											if (!widget.disableUpdates && !widget.disableBottomUpdates) SliverSafeArea(
												top: false,
												sliver: SliverToBoxAdapter(
													child: RepaintBoundary(
														child: RefreshableListFooter(
															key: _footerKey,
															updater: _updateOrExtendWithHapticFeedback,
															updatingNow: updatingNow.value,
															lastUpdateTime: lastUpdateTime,
															nextUpdateTime: nextUpdateTime,
															errorMessage: errorMessage,
															remedy: widget.remedies[errorType]?.call(context, _updateOrExtendWithHapticFeedback),
															overscrollFactor: widget.controller?.overscrollFactor,
															pointerDownNow: () {
																return _pointerDownCount > 0;
															}
														)
													)
												)
											)
										]
									)
								)
							)
						)
					)
				)
			);
		}
		else if (errorMessage != null) {
			return Center(
				child: Column(
					mainAxisAlignment: MainAxisAlignment.center,
					children: [
						ErrorMessageCard('Error loading ${widget.id}:\n${errorMessage?.toStringDio()}'),
						CupertinoButton(
							onPressed: _updateWithHapticFeedback,
							child: const Text('Retry')
						),
						if (widget.remedies[errorType] != null) widget.remedies[errorType]!(context, _updateWithHapticFeedback),
						if (widget.initialList?.isNotEmpty ?? false) CupertinoButton(
							onPressed: () {
								originalList = widget.initialList;
								sortedList = originalList?.toList();
								if (sortedList != null) {
									_sortList();
								}
								setState(() {});
							},
							child: const Text('View cached')
						)
					]
				)
			);
		}
		else {
			return const Center(
				child: CupertinoActivityIndicator()
			);
		}
	}
}

class RefreshableListFooter extends StatelessWidget {
	final String? errorMessage;
	final VoidCallback updater;
	final bool updatingNow;
	final DateTime? lastUpdateTime;
	final DateTime? nextUpdateTime;
	final Widget? remedy;
	final ValueListenable<double>? overscrollFactor;
	final bool Function() pointerDownNow;
	const RefreshableListFooter({
		required this.updater,
		required this.updatingNow,
		this.lastUpdateTime,
		this.nextUpdateTime,
		this.errorMessage,
		this.remedy,
		this.overscrollFactor,
		required this.pointerDownNow,
		Key? key
	}) : super(key: key);

	@override
	Widget build(BuildContext context) {
		return GestureDetector(
			behavior: HitTestBehavior.opaque,
			onTap: updatingNow ? null : updater,
			child: Container(
				color: errorMessage != null ? Colors.orange.withOpacity(0.5) : null,
				padding: const EdgeInsets.all(1),
				child: Center(
					child: Column(
						mainAxisSize: MainAxisSize.min,
						children: [
							if (errorMessage != null) ...[
								const SizedBox(height: 16),
								Text(
									errorMessage!,
									textAlign: TextAlign.center
								),
								const SizedBox(height: 16)
							],
							if (!updatingNow && remedy != null) ...[
								remedy!,
								const SizedBox(height: 16)
							],
							if (overscrollFactor != null) SizedBox(
								height: updatingNow ? 64 : 0,
								child: OverflowBox(
									maxHeight: 100,
									alignment: Alignment.topCenter,
									child: ValueListenableBuilder(
										valueListenable: overscrollFactor!,
										builder: (context, double value, child) => TweenAnimationBuilder(
											tween: Tween<double>(begin: 0, end: value),
											duration: const Duration(milliseconds: 50),
											curve: Curves.ease,
											builder: (context, double smoothedValue, child) => Stack(
												alignment: Alignment.topCenter,
												clipBehavior: Clip.none,
												children: [
													Positioned(
														top: 0,
														child: Container(
															padding: const EdgeInsets.only(top: 32),
															constraints: const BoxConstraints(
																maxWidth: 100
															),
															child: ClipRRect(
																borderRadius: const BorderRadius.all(Radius.circular(8)),
																child: Stack(
																	children: [
																		if (nextUpdateTime != null && lastUpdateTime != null) TimedRebuilder(
																			enabled: true,
																			interval: const Duration(seconds: 1),
																			builder: (context) {
																				final now = DateTime.now();
																				return LinearProgressIndicator(
																					value: updatingNow ? 0 : now.difference(lastUpdateTime!).inSeconds / nextUpdateTime!.difference(lastUpdateTime!).inSeconds,
																					color: CupertinoTheme.of(context).primaryColor.withOpacity(0.5),
																					backgroundColor: CupertinoTheme.of(context).primaryColorWithBrightness(0.1),
																					minHeight: 8
																				);
																			}
																		),
																		LinearProgressIndicator(
																			value: (updatingNow) ? null : (pointerDownNow() ? smoothedValue : 0),
																			backgroundColor: Colors.transparent,
																			color: CupertinoTheme.of(context).primaryColor,
																			minHeight: 8
																		)
																	]
																)
															)
														)
													),
													if (nextUpdateTime?.isAfter(DateTime.now()) ?? false) Positioned(
														top: 50,
														child: TimedRebuilder(
															enabled: nextUpdateTime != null && lastUpdateTime != null,
															interval: const Duration(seconds: 1),
															builder: (context) {
																return GreedySizeCachingBox(
																	child: Text('Next update ${formatRelativeTime(nextUpdateTime ?? DateTime(3000))}', style: TextStyle(
																		color: CupertinoTheme.of(context).primaryColorWithBrightness(0.5)
																	))
																);
															}
														)
													)
												]
											)
										)
									)
								)
							)
						]
					)
				)
			)
		);
	}
}

class _BuiltRefreshableListItem<T extends Object> {
	BuildContext? context;
	T item;
	double? cachedOffset;
	double? cachedHeight;
	bool get hasGoodState {
		try {
			return (context?.findRenderObject()?.attached ?? false) && ((context?.findRenderObject() as RenderBox).hasSize);
		}
		on FlutterError {
			return false;
		}
	}
	_BuiltRefreshableListItem(this.item);

	@override
	bool operator == (dynamic o) => (o is _BuiltRefreshableListItem<T>) && o.item == item;

	@override
	int get hashCode => item.hashCode;

	@override
	String toString() => '_RefreshableListItem(item: $item, cachedOffset: $cachedOffset, cachedHeight: $cachedHeight)';
}
class RefreshableListController<T extends Object> extends ChangeNotifier {
	List<_BuiltRefreshableListItem<RefreshableListItem<T>>> _items = [];
	Iterable<RefreshableListItem<T>> get items => _items.map((i) => i.item);
	int get itemsLength => _items.length;
	RefreshableListItem<T> getItem(int i) => _items[i].item;
	ScrollController? scrollController;
	late final ValueNotifier<double> overscrollFactor = ValueNotifier<double>(0);
	late final BehaviorSubject<void> _scrollStream = BehaviorSubject();
	late final EasyListenable slowScrolls = EasyListenable();
	late final StreamSubscription<List<void>> _slowScrollSubscription;
	double? topOffset;
	double? bottomOffset;
	String? contentId;
	RefreshableListState<T>? state;
	final Map<(int, bool), List<Completer<void>>> _itemCacheCallbacks = {};
	int? currentTargetIndex;
	RefreshableListController() {
		_slowScrollSubscription = _scrollStream.bufferTime(const Duration(milliseconds: 100)).where((batch) => batch.isNotEmpty).listen(_onSlowScroll);
		SchedulerBinding.instance.endOfFrame.then((_) => _onScrollControllerNotification());
	}
	void invalidateAfter(RefreshableListItem<T> item, bool looseEquality) {
		final index = looseEquality ?
			_items.indexWhere((i) => i.item.item == item.item) :
			_items.indexWhere((i) => i.item == item);
		if (index == -1) {
			print('Could not find $item in list to invalidate after');
		}
		for (final item in _items.skip(index + 1)) {
			item.cachedOffset = null;
			item.cachedHeight = null;
		}
	}
	Future<void> _tryCachingItem(int index, _BuiltRefreshableListItem<RefreshableListItem<T>> item) async {
		await SchedulerBinding.instance.endOfFrame;
		if (item.hasGoodState) {
			// ignore: use_build_context_synchronously
			final RenderObject object = item.context!.findRenderObject()!;
			item.cachedHeight = object.semanticBounds.height;
			final newOffset = _getOffset(object);
			if (item.cachedOffset != null && item.cachedOffset != newOffset) {
				for (final item in _items.skip(index + 1)) {
					item.cachedOffset = null;
				}
			}
			item.cachedOffset = newOffset;
			final keys = _itemCacheCallbacks.keys.toList();
			for (final position in keys) {
				if (position.$2 && index >= position.$1) {
					// scrolling down
					_itemCacheCallbacks[position]?.forEach((c) => c.complete());
					_itemCacheCallbacks.remove(position);
				}
				else if (!position.$2 && index <= position.$1) {
					// scrolling up
					_itemCacheCallbacks[position]?.forEach((c) => c.complete());
					_itemCacheCallbacks.remove(position);
				}
			}
		}
	}
	Future<void> _onSlowScroll(void update) async {
		for (final item in _items) {
			if (item.context?.mounted == false) {
				item.context = null;
			}
		}
		slowScrolls.didUpdate();
	}
	void _onScrollControllerNotification() {
		_scrollStream.add(null);
		if ((scrollControllerPositionLooksGood)) {
			final overscrollAmount = scrollController!.position.pixels - scrollController!.position.maxScrollExtent;
			overscrollFactor.value = (overscrollAmount / _overscrollTriggerThreshold).clamp(0, 1);
		}
	}
	void attach(RefreshableListState<T> list) {
		state = list;
	}
	void focusSearch() {
		state?._focusSearch();
	}
	void reportPrimaryScrollController(ScrollController? controller) {
		if (scrollController != controller) {
			scrollController?.removeListener(_onScrollControllerNotification);
			scrollController = controller;
			scrollController?.addListener(_onScrollControllerNotification);
		}
	}
	@override
	void dispose() {
		super.dispose();
		_scrollStream.close();
		_slowScrollSubscription.cancel();
		scrollController?.removeListener(_onScrollControllerNotification);
		slowScrolls.dispose();
		overscrollFactor.dispose();
	}
	void newContentId(String contentId) {
		if (this.contentId != null && this.contentId != contentId) {
			for (final cbs in _itemCacheCallbacks.values) {
				for (final cb in cbs) {
					cb.completeError(Exception('page changed'));
				}
			}
			_items = [];
			_itemCacheCallbacks.clear();
		}
		this.contentId = contentId;
	}
	void setItems(List<RefreshableListItem<T>> items) {
		final oldFirstOffset = _items.tryFirst?.cachedOffset;
		if (items.length > 2 &&
		   _items.length > 2 &&
			 items[0] == _items[0].item &&
			 items[1] == _items[1].item &&
			 items.length >= _items.length &&
			 state?.useTree != true) {
			if (items.length < _items.length) {
				_items = _items.sublist(0, items.length);
			}
			for (int i = 0; i < items.length; i++) {
				if (i < _items.length) {
					_items[i].item = items[i];
				}
				else {
					_items.add(_BuiltRefreshableListItem(items[i]));
				}
			}
		}
		else if (items.length == 1 && _items.length == 1 && items[0] == _items[0].item) {
			_items[0].item = items[0];
		}
		else if (!listEquals(items, this.items.toList())) {
			final oldCachedHeights = <RefreshableListItem<T>, double>{
				for (final item in _items)
					if (item.cachedHeight != null)
						item.item: item.cachedHeight!
			};
			_items = items.map((item) => _BuiltRefreshableListItem(item)..cachedHeight = oldCachedHeights[item]).toList();
		}
		_items.tryFirst?.cachedOffset = oldFirstOffset;
		WidgetsBinding.instance.addPostFrameCallback((_) => notifyListeners());
	}
	void registerItem(int index, RefreshableListItem<T> item, BuildContext context) {
		if (index < _items.length) {
			_items[index].item = item;
			_items[index].context = context;
		}
	}
	double _getOffset(RenderObject object) {
		return RenderAbstractViewport.of(object).getOffsetToReveal(object, 0.0).offset;
	}
	double? _estimateOffset(int targetIndex) {
		final heightedItems = _items.map((i) => i.cachedHeight).where((i) => i != null);
		final averageItemHeight = heightedItems.map((i) => i!).fold<double>(0, (a, b) => a + b) / heightedItems.length;
		int nearestDistance = _items.length + 1;
		double? estimate;
		for (int i = 0; i < _items.length; i++) {
			if (_items[i].cachedOffset != null) {
				final distance = (targetIndex - i).abs();
				if (distance < nearestDistance) {
					estimate = _items[i].cachedOffset! + (averageItemHeight * (targetIndex - i));
					nearestDistance = distance;
				}
			}
		}
		return estimate;
	}
	Future<void> animateTo(bool Function(T val) f, {double alignment = 0.0, bool Function(T val)? orElseLast, Duration duration = const Duration(milliseconds: 200)}) async {
		int targetIndex = _items.indexWhere((i) => f(i.item.item));
		if (targetIndex == -1) {
			if (orElseLast != null) {
				targetIndex = _items.lastIndexWhere((i) => orElseLast(i.item.item));
			}
			if (targetIndex == -1) {
				throw const ItemNotFoundException('No matching item to scroll to');
			}
		}
		await animateToIndex(targetIndex, alignment: alignment, duration: duration);
	}
	Future<void> animateToIndex(int targetIndex, {double alignment = 0.0, Duration duration = const Duration(milliseconds: 200)}) async {
		print('$contentId animating to $targetIndex');
		final start = DateTime.now();
		currentTargetIndex = targetIndex;
		Duration d = duration;
		Curve c = Curves.easeIn;
		final initialContentId = contentId;
		Future<bool> attemptResolve() async {
			final completer = Completer<void>();
			double estimate = (_estimateOffset(targetIndex) ?? ((targetIndex > (_items.length / 2)) ? scrollController!.position.maxScrollExtent : 0)) - topOffset!;
			if (_items.last.cachedOffset != null) {
				// prevent overscroll
				estimate = min(estimate, scrollController!.position.maxScrollExtent);
			}
			_itemCacheCallbacks.putIfAbsent((targetIndex, estimate > scrollController!.position.pixels), () => []).add(completer);
			final delay = Duration(milliseconds: min(300, max(1, (estimate - scrollController!.position.pixels).abs() ~/ 100)));
			scrollController!.animateTo(
				estimate,
				duration: delay,
				curve: c
			);
			await Future.any([completer.future, Future.wait([Future.delayed(const Duration(milliseconds: 32)), Future.delayed(delay ~/ 4)])]);
			return (_items[targetIndex].cachedOffset != null);
		}
		if (_items[targetIndex].cachedOffset == null) {
			while (contentId == initialContentId && !(await attemptResolve()) && DateTime.now().difference(start).inSeconds < 5 && targetIndex == currentTargetIndex) {
				c = Curves.linear;
			}
			if (initialContentId != contentId) {
				print('List was hijacked ($initialContentId -> $contentId)');
				return;
			}
			if (currentTargetIndex != targetIndex) {
				print('animateTo was hijacked ($targetIndex -> $currentTargetIndex)');
				return;
			}
			Duration timeLeft = duration - DateTime.now().difference(start);
			d = Duration(milliseconds: max(timeLeft.inMilliseconds, duration.inMilliseconds ~/ 4));
		}
		if (_items[targetIndex].cachedOffset == null) {
			throw Exception('Scrolling timed out');
		}
		double atAlignment0 = _items[targetIndex].cachedOffset! - topOffset!;
		final alignmentSlidingWindow = scrollController!.position.viewportDimension - _items[targetIndex].cachedHeight! - topOffset! - bottomOffset!;
		if (_items[targetIndex] == _items.last) {
			// add offset to reveal the full footer
			atAlignment0 += 110;
		}
		else {
			atAlignment0 += 1;
		}
		double finalDestination = (atAlignment0 - (alignmentSlidingWindow * alignment)).clamp(0, scrollController!.position.maxScrollExtent);
		await scrollController!.animateTo(
			max(0, finalDestination),
			duration: Duration(milliseconds: max(1, d.inMilliseconds)),
			curve: Curves.easeOut
		);
		await SchedulerBinding.instance.endOfFrame;
	}
	void cancelCurrentAnimation() {
		currentTargetIndex = null;
	}
	int get firstVisibleIndex {
		if (scrollControllerPositionLooksGood) {
			if (_items.isNotEmpty &&
					_items.first.cachedOffset != null &&
					_items.first.cachedOffset! > scrollController!.position.pixels) {
				// Search field will mean that the _items.lastIndexWhere search will return -1
				return 0;
			}
			return _items.lastIndexWhere((i) => (i.cachedOffset != null) && (i.cachedOffset! <= scrollController!.position.pixels));
		}
		return -1;
	}
	T? get firstVisibleItem {
		final index = firstVisibleIndex;
		return index < 0 ? null : _items[index].item.item;
	}
	T? get middleVisibleItem {
		if (scrollControllerPositionLooksGood) {
			int index = _items.indexWhere((i) => (i.cachedOffset != null) && (i.cachedOffset! > (scrollController!.position.pixels + (scrollController!.position.viewportDimension / 2))));
			if (index != -1) {
				if (index > 0) {
					// It will be one too far, we want the item which covers the middle pixel row
					index--;
				}
				return _items[index].item.item;
			}
		}
		return null;
	}
	int get lastVisibleIndex {
		if (scrollControllerPositionLooksGood) {
			if (_items.isNotEmpty &&
					_items.first.cachedHeight != null &&
					_items.first.cachedHeight! > (scrollController!.position.pixels + scrollController!.position.viewportDimension)) {
				return 0;
			}
			return _items.lastIndexWhere((i) => (i.cachedOffset != null) && i.cachedOffset! < (scrollController!.position.pixels + scrollController!.position.viewportDimension));
		}
		return -1;
	}
	T? get lastVisibleItem {
		final index = lastVisibleIndex;
		return index < 0 ? null : _items[index].item.item;
	}
	bool isOnscreen(T item) {
		if (scrollControllerPositionLooksGood) {
			return _items.any((i) {
				return (i.item.item == item) &&
							 (i.cachedHeight != null) &&
							 (i.cachedOffset != null) && 
							 (i.cachedOffset! + i.cachedHeight! > scrollController!.position.pixels) &&
							 (i.cachedOffset! < (scrollController!.position.pixels + scrollController!.position.viewportDimension));
			});
		}
		return false;
	}
	Future<void> blockAndUpdate() async {
		state?.originalList = null;
		state?.sortedList = null;
		setItems([]);
		await state?.update();
		slowScrolls.didUpdate();
	}
	Future<void> update() async {
		await state?.update();
	}
	Future<void> _alignToItemIfPartiallyAboveFold(RefreshableListItem<T> item) async {
		final found = _items.tryFirstWhere((i) => i.item == item);
		if (found != null && found.cachedOffset != null && (found.cachedOffset! < (scrollController?.offset ?? 0))) {
			scrollController?.animateTo(
				found.cachedOffset!,
				duration: const Duration(milliseconds: 200),
				curve: Curves.ease
			);
		}
	}

	Future<void> waitForItemBuild(int item) async {
		if (_items.length > item && _items[item].hasGoodState) {
			return;
		}
		final c = Completer();
		_itemCacheCallbacks.putIfAbsent(const (0, true), () => []).add(c);
		await c.future;
	}

	TreeItemCollapseType? isItemHidden(RefreshableListItem<T> item) {
		return state?._refreshableTreeItems.isItemHidden(item._key);
	}

	void didFinishLayout(int startIndex, int endIndex) {
		for (int i = startIndex; i <= endIndex; i++) {
			_tryCachingItem(i, _items[i]);
		}
	}

	bool get scrollControllerPositionLooksGood => scrollController?.hasOnePosition ?? false;
}
