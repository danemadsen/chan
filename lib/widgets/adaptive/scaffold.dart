import 'package:chan/main.dart';
import 'package:chan/pages/master_detail.dart';
import 'package:chan/services/settings.dart';
import 'package:chan/services/theme.dart';
import 'package:chan/widgets/scroll_tracker.dart';
import 'package:chan/widgets/util.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

class AdaptiveBar {
	final List<Widget>? leadings;
	final Widget? title;
	final List<Widget>? actions;
	final Color? backgroundColor;
	final Brightness? brightness;
	
	const AdaptiveBar({
		this.leadings,
		this.title,
		this.actions,
		this.backgroundColor,
		this.brightness
	});
}

class _AppBarWithBackButtonPriority extends StatelessWidget implements PreferredSizeWidget {
	final AdaptiveBar bar;
	final VoidCallback? onDrawerButtonPressed;
	final bool autoHideOnScroll;

	const _AppBarWithBackButtonPriority({
		required this.bar,
		required this.autoHideOnScroll,
		this.onDrawerButtonPressed
	});

	@override
	Widget build(BuildContext context) {
		final leadings = <Widget>[];
		if (ModalRoute.of(context)?.canPop ?? false) {
			leadings.add(const BackButton());
		}
		else if (onDrawerButtonPressed != null) {
			leadings.add(GestureDetector(
				onLongPress: () {
					Settings.instance.runQuickAction(context);
				},
				child: DrawerButton(
					onPressed: onDrawerButtonPressed
				)
			));
		}
		if (bar.leadings != null) {
			leadings.addAll(bar.leadings!);
		}
		final child = AppBar(
			leadingWidth: leadings.length > 1 ? leadings.length * 48 : null,
			leading: leadings.isEmpty ? null : Row(
				mainAxisSize: MainAxisSize.min,
				children: leadings
			),
			surfaceTintColor: Colors.transparent,
			foregroundColor: ChanceTheme.primaryColorOf(context),
			//centerTitle: true,
			title: Container(
				height: 44,
				alignment: Alignment.centerLeft,
				child: bar.title
			),
			actions: bar.actions,
			backgroundColor: bar.backgroundColor,
			systemOverlayStyle: SystemUiOverlayStyle(
				statusBarBrightness: bar.brightness ?? ChanceTheme.brightnessOf(context),
				statusBarIconBrightness: (bar.brightness ?? ChanceTheme.brightnessOf(context)).inverted
			)
		);
		if (!autoHideOnScroll) {
			return child;
		}
		return AncestorScrollBuilder(
			builder: (context, direction, _) => AnimatedOpacity(
				opacity: direction == VerticalDirection.up ? 1.0 : 0.0,
				duration: const Duration(milliseconds: 350),
				curve: Curves.ease,
				child: IgnorePointer(
					ignoring: direction == VerticalDirection.down,
					child: child
				)
			)
		);
	}
	
	@override
	Size get preferredSize => const Size.fromHeight(kToolbarHeight);
}

class _CupertinoNavigationBar extends StatelessWidget implements ObstructingPreferredSizeWidget {
	final bool transitionBetweenRoutes;
	final Widget? leading;
	final Widget? middle;
	final Color? backgroundColor;
	final Widget? trailing;
	final Brightness brightness;
	final bool autoHideOnScroll;

	const _CupertinoNavigationBar({
		required this.autoHideOnScroll,
		this.transitionBetweenRoutes = true,
		this.leading,
		this.middle,
		this.backgroundColor,
		this.trailing,
		required this.brightness
	});

	@override
	bool shouldFullyObstruct(BuildContext context) {
		return !autoHideOnScroll && backgroundColor?.opacity == 1;
	}

	@override
	Size get preferredSize => const Size.fromHeight(kMinInteractiveDimensionCupertino);

	@override
	Widget build(BuildContext context) {
		final child = CupertinoNavigationBar(
			transitionBetweenRoutes: transitionBetweenRoutes,
			leading: leading,
			middle: middle,
			backgroundColor: backgroundColor,
			trailing: trailing,
			brightness: brightness
		);
		if (!autoHideOnScroll) {
			return child;
		}
		return AncestorScrollBuilder(
			builder: (context, direction, _) => AnimatedOpacity(
				opacity: direction == VerticalDirection.up ? 1.0 : 0.0,
				duration: const Duration(milliseconds: 350),
				curve: Curves.ease,
				child: IgnorePointer(
					ignoring: direction == VerticalDirection.down,
					child: child
				)
			)
		);
	}
}

class _CupertinoDrawer {
	final GlobalKey<DrawerControllerState> key;
	const _CupertinoDrawer(this.key);

	@override
	bool operator == (Object other) => other is _CupertinoDrawer && other.key == key;
	@override
	int get hashCode => key.hashCode;
}

class AdaptiveScaffold extends StatefulWidget {
	final Color? backgroundColor;
	final Widget body;
	final AdaptiveBar? bar;
	final bool resizeToAvoidBottomInset;
	final Widget? drawer;
	final bool disableAutoBarHiding;

	const AdaptiveScaffold({
		required this.body,
		this.bar,
		this.backgroundColor,
		this.resizeToAvoidBottomInset = true,
		this.drawer,
		this.disableAutoBarHiding = false,
		super.key
	});

	@override
	createState() => AdaptiveScaffoldState();
}

class AdaptiveScaffoldState extends State<AdaptiveScaffold> {
	final _materialScaffoldKey = GlobalKey<ScaffoldState>(debugLabel: 'AdaptiveScaffold._materialScaffoldKey');
	final _cupertinoDrawer = _CupertinoDrawer(GlobalKey<DrawerControllerState>(debugLabel: 'AdaptiveScaffold._cupertinoDrawerKey'));
	bool _isCupertinoDrawerOpen = false;

	bool get isDrawerOpen {
		if (Settings.instance.materialStyle) {
			return _materialScaffoldKey.currentState?.isDrawerOpen ?? false;
		}
		return _isCupertinoDrawerOpen;
	}

	void closeDrawer() {
		if (Settings.instance.materialStyle) {
			_materialScaffoldKey.currentState?.closeDrawer();
		}
		else {
			_cupertinoDrawer.key.currentState?.close();
		}
	}

	double _calculateWideDrawerEdgeDragWidth(BuildContext context) {
		final factor = Settings.openBoardSwitcherSlideGestureSetting.watch(context) ? 0.5 : 1;
		final twoPaneBreakpoint = Settings.twoPaneBreakpointSetting.watch(context);
		final size = MediaQuery.sizeOf(context);
		if (size.width < twoPaneBreakpoint) {
			// Based on full screen width for one-pane
			return size.width * factor;
		}
		final twoPaneSplit = Settings.twoPaneSplitSetting.watch(context) / twoPaneSplitDenominator;
		// Based on master pane width for two-pane
		return size.width * factor * twoPaneSplit;
	}

	@override
	Widget build(BuildContext context) {
		final bar_ = widget.bar;
		final autoHideBars = !widget.disableAutoBarHiding && Settings.hideBarsWhenScrollingDownSetting.watch(context);
		if (ChanceTheme.materialOf(context)) {
			VoidCallback? onDrawerButtonPressed;
			final parentScaffold = Scaffold.maybeOf(context);
			if (parentScaffold?.hasDrawer ?? false) {
				onDrawerButtonPressed = parentScaffold?.openDrawer;
			}
			if (context.read<MasterDetailHint?>()?.location.isDetail ?? false) {
				// Only show drawer on master
				onDrawerButtonPressed = null;
			}
			return Scaffold(
				key: _materialScaffoldKey,
				drawer: widget.drawer,
				drawerEdgeDragWidth: (widget.drawer != null && context.select<ChanTabs?, bool>((t) => t?.shouldEnableWideDrawerGesture ?? false)) ? _calculateWideDrawerEdgeDragWidth(context) : null,
				extendBodyBehindAppBar: autoHideBars || (bar_?.backgroundColor?.opacity ?? 1) < 1,
				resizeToAvoidBottomInset: widget.resizeToAvoidBottomInset,
				backgroundColor: widget.backgroundColor,
				appBar: bar_ == null ? null : _AppBarWithBackButtonPriority(
					autoHideOnScroll: autoHideBars,
					bar: bar_,
					onDrawerButtonPressed: onDrawerButtonPressed
				),
				body: widget.body,
			);
		}
		final parentDrawer = context.watch<_CupertinoDrawer?>();
		final leadings = <Widget>[];
		if (!(ModalRoute.of(context)?.canPop ?? false) &&
		    parentDrawer != null &&
				context.read<MasterDetailHint?>()?.location.isDetail != true) {
			// Only if at root route
			leadings.add(CupertinoButton(
				onPressed: () => parentDrawer.key.currentState?.open(),
				minSize: 0,
				padding: EdgeInsets.zero,
				child: const Icon(Icons.menu)
			));
		}
		if (bar_?.leadings != null) {
			leadings.addAll(bar_!.leadings!);
		}
		final child = CupertinoPageScaffold(
			resizeToAvoidBottomInset: widget.resizeToAvoidBottomInset,
			backgroundColor: widget.backgroundColor,
			navigationBar: bar_ == null ? null : _CupertinoNavigationBar(
				autoHideOnScroll: autoHideBars,
				transitionBetweenRoutes: false,
				leading: leadings.isEmpty ? null : Row(
					mainAxisSize: MainAxisSize.min,
					children: leadings
				),
				middle: bar_.title,
				backgroundColor: bar_.backgroundColor,
				trailing: bar_.actions == null ? null : Row(
					mainAxisSize: MainAxisSize.min,
					children: bar_.actions!
				),
				brightness: bar_.brightness ?? ChanceTheme.brightnessOf(context)
			),
			child: widget.body
		);
		final drawer_ = widget.drawer;
		if (drawer_ == null) {
			return child;
		}
		return Provider<_CupertinoDrawer>.value(
			value: _cupertinoDrawer,
			builder: (context, _) => Stack(
				children: [
					child,
					DrawerController(
						edgeDragWidth: context.select<ChanTabs?, bool>((t) => t?.shouldEnableWideDrawerGesture ?? false) ? _calculateWideDrawerEdgeDragWidth(context) : null,
						drawerCallback: (isOpen) {
							_isCupertinoDrawerOpen = isOpen;
						},
						key: context.watch<_CupertinoDrawer>().key,
						alignment: DrawerAlignment.start,
						child: drawer_
					)
				]
			)
		);
	}
}