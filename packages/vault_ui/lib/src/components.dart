import 'dart:io';

import 'package:flutter/material.dart';

import 'package:vault_ui/src/study_controller.dart';

/// Warm editorial surfaces and evergreen accents shared by Vault's interfaces.
ThemeData vaultTheme({required bool dark, bool highContrast = false}) {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xFF286451),
        brightness: dark ? Brightness.dark : Brightness.light,
        contrastLevel: highContrast ? 1 : 0,
      ).copyWith(
        primary: dark ? const Color(0xFFA4D5BF) : const Color(0xFF245C49),
        onPrimary: dark ? const Color(0xFF123B2D) : Colors.white,
        primaryContainer: dark
            ? const Color(0xFF244C3D)
            : const Color(0xFFDCECE1),
        onPrimaryContainer: dark
            ? const Color(0xFFD3EFDF)
            : const Color(0xFF173F30),
        surface: dark ? const Color(0xFF121714) : const Color(0xFFF7F7F2),
        onSurface: dark ? const Color(0xFFE9EDE6) : const Color(0xFF202A24),
        onSurfaceVariant: highContrast
            ? dark
                  ? const Color(0xFFE9EDE6)
                  : const Color(0xFF202A24)
            : dark
            ? const Color(0xFFB6C2B8)
            : const Color(0xFF59665D),
        surfaceContainerLowest: dark
            ? const Color(0xFF19211C)
            : const Color(0xFFFEFEFA),
        surfaceContainerLow: dark
            ? const Color(0xFF1E2721)
            : const Color(0xFFF0F2EA),
        surfaceContainer: dark
            ? const Color(0xFF253027)
            : const Color(0xFFEAEDE4),
        surfaceContainerHigh: dark
            ? const Color(0xFF2B372E)
            : const Color(0xFFE3E8DD),
        surfaceContainerHighest: dark
            ? const Color(0xFF344138)
            : const Color(0xFFDCE3D6),
        outline: highContrast
            ? dark
                  ? const Color(0xFFE9EDE6)
                  : const Color(0xFF202A24)
            : dark
            ? const Color(0xFF8F9D92)
            : const Color(0xFF778579),
        outlineVariant: highContrast
            ? dark
                  ? const Color(0xFF8F9D92)
                  : const Color(0xFF778579)
            : dark
            ? const Color(0xFF38473C)
            : const Color(0xFFDEE4D9),
      );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    fontFamily: 'Roboto',
    materialTapTargetSize: MaterialTapTargetSize.padded,
  );
  final buttonShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(14),
  );
  final inputShape = BorderRadius.circular(14);
  return base.copyWith(
    textTheme: base.textTheme.copyWith(
      displaySmall: base.textTheme.displaySmall?.copyWith(
        fontFamily: 'VaultSerif',
        fontSize: 32,
        fontWeight: FontWeight.w500,
        height: 1.2,
        letterSpacing: -1.1,
      ),
      headlineSmall: base.textTheme.headlineSmall?.copyWith(
        fontFamily: 'VaultSerif',
        fontSize: 28,
        fontWeight: FontWeight.w500,
        height: 1.2,
        letterSpacing: -.5,
      ),
      titleLarge: base.textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
        height: 1.3,
        letterSpacing: -.3,
      ),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
        height: 1.4,
      ),
      titleSmall: base.textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.w600,
        height: 1.4,
      ),
      bodyLarge: base.textTheme.bodyLarge?.copyWith(height: 1.5),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(height: 1.5),
      bodySmall: base.textTheme.bodySmall?.copyWith(height: 1.5),
      labelLarge: base.textTheme.labelLarge?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: .1,
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w700,
        letterSpacing: -.5,
      ),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: buttonShape,
        textStyle: base.textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: buttonShape,
        side: BorderSide(color: scheme.outline),
        textStyle: base.textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: buttonShape,
        textStyle: base.textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primaryContainer,
      elevation: 0,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surfaceContainerLowest,
      indicatorColor: scheme.primaryContainer,
      selectedIconTheme: IconThemeData(color: scheme.onPrimaryContainer),
      unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      selectedLabelTextStyle: base.textTheme.labelMedium?.copyWith(
        color: scheme.primary,
        fontWeight: FontWeight.w600,
      ),
      unselectedLabelTextStyle: base.textTheme.labelMedium?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: scheme.onSurfaceVariant,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLowest,
      hintStyle: TextStyle(color: scheme.onSurfaceVariant),
      border: OutlineInputBorder(
        borderRadius: inputShape,
        borderSide: BorderSide(color: scheme.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: inputShape,
        borderSide: BorderSide(color: scheme.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: inputShape,
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: inputShape,
        borderSide: BorderSide(color: scheme.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: inputShape,
        borderSide: BorderSide(color: scheme.error, width: 2),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: inputShape,
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    ),
  );
}

/// Responsive page heading, with action moved below text on small screens.
class VaultPageHeader extends StatelessWidget {
  /// Creates a header that remains usable with large text and narrow widths.
  const new({
    required this.eyebrow,
    required this.title,
    required this.subtitle,
    this.action,
    super.key,
  });

  /// Short uppercase section description.
  final String eyebrow;

  /// Main heading.
  final String title;

  /// Honest context or availability explanation.
  final String subtitle;

  /// Optional primary page action.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final copy = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          eyebrow.toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(height: 8),
        Text(title, style: theme.textTheme.displaySmall),
        const SizedBox(height: 8),
        Text(
          subtitle,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 650) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                copy,
                if (action != null) ...[const SizedBox(height: 18), action!],
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(child: copy),
              if (action != null) ...[const SizedBox(width: 24), action!],
            ],
          );
        },
      ),
    );
  }
}

/// Bordered surface for a related set of controls or content.
class SectionCard extends StatelessWidget {
  /// Creates a semantic group with an optional title.
  const new({
    required this.child,
    this.title,
    this.padding = const EdgeInsets.all(20),
    super.key,
  });

  /// Optional section title.
  final String? title;

  /// Main content.
  final Widget child;

  /// Inner content spacing.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(20),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null) ...[
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                title!,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const Divider(),
          ],
          Padding(padding: padding, child: child),
        ],
      ),
    );
  }
}

/// Semantic status colors, always accompanied by a text label.
enum StatusTone {
  /// Neutral descriptive state.
  neutral,

  /// Approved or confirmed state.
  positive,

  /// A decision or recovery action needs attention.
  attention,

  /// Access is stopped or blocked.
  negative,
}

/// Compact status label; not an interactive control.
class StateChip extends StatelessWidget {
  /// Creates a label without implying connectivity from an access state.
  const new(this.label, {this.tone = StatusTone.neutral, this.icon, super.key});

  /// Human-readable state.
  final String label;

  /// Semantic tone.
  final StatusTone tone;

  /// Optional secondary visual cue.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = switch (tone) {
      StatusTone.neutral => colors.onSurfaceVariant,
      StatusTone.positive =>
        colors.brightness == Brightness.dark
            ? const Color(0xFF9ED9B5)
            : const Color(0xFF236444),
      StatusTone.attention =>
        colors.brightness == Brightness.dark
            ? const Color(0xFFF1C590)
            : const Color(0xFF875221),
      StatusTone.negative => colors.error,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 5),
          ],
          Flexible(
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// Contextual information with one optional corrective action.
class InfoStrip extends StatelessWidget {
  /// Creates a non-modal status explanation.
  const new({
    required this.title,
    required this.message,
    this.icon = Icons.info_outline,
    this.action,
    super.key,
  });

  /// Concise, factual diagnosis.
  final String title;

  /// Explanation without an unproven cause or promise.
  final String message;

  /// Supporting non-color cue.
  final IconData icon;

  /// Optional recovery action.
  final Widget? action;

  @override
  Widget build(BuildContext context) => SectionCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(message, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
        if (action != null) ...[const SizedBox(height: 12), action!],
      ],
    ),
  );
}

/// Bounded thumbnail decoding for bundled or selected local media.
class MediaThumb extends StatelessWidget {
  /// Creates a thumbnail without opening video playback.
  const new({required this.item, this.fit = BoxFit.cover, super.key});

  /// Media entry to display.
  final LibraryItem item;

  /// Image sizing behavior.
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final source =
        item.thumbnail ?? (item.kind == MediaKind.photo ? item.path : null);
    if (source == null) {
      return ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: const Center(child: Icon(Icons.play_circle_outline, size: 36)),
      );
    }
    Widget failed(BuildContext context, Object error, StackTrace? stack) =>
        ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Center(child: Icon(Icons.broken_image_outlined)),
        );
    return item.isAsset
        ? Image.asset(
            source,
            fit: fit,
            width: double.infinity,
            height: double.infinity,
            cacheWidth: 900,
            errorBuilder: failed,
            excludeFromSemantics: true,
          )
        : Image.file(
            File(source),
            fit: fit,
            width: double.infinity,
            height: double.infinity,
            cacheWidth: 900,
            errorBuilder: failed,
            excludeFromSemantics: true,
          );
  }
}

/// Shared footer distinguishing the local preview from a cloud service.
class PrivacyFooter extends StatelessWidget {
  /// Creates the small privacy/status footer.
  const new({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 28, bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        const SizedBox(height: 16),
        Text(
          'Local-first. Shared on your terms.\n'
          'Interface preview · no peer media delivery',
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ],
    ),
  );
}
