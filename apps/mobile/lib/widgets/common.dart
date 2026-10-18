import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../core/api.dart';
import '../core/money.dart';
import '../core/theme.dart';

const kDisclaimer = 'CASCADE is an informational risk tool, not a financial adviser. Projections are what-if '
    'calculations from the data you provide, not predictions or guarantees.';

String fmtDate(String? iso, {bool year = false}) {
  if (iso == null) return '—';
  final d = DateTime.tryParse(iso);
  return d == null ? iso : DateFormat(year ? 'd MMM y' : 'd MMM').format(d);
}

String errorText(Object e) => e is ApiException ? e.message : 'Something went wrong. Please try again.';

void showSnack(BuildContext c, String msg, {SnackBarAction? action}) {
  ScaffoldMessenger.of(c)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg), action: action));
}

Future<bool> confirmDialog(BuildContext c, {required String title, required String body, String confirm = 'Delete'}) async {
  final r = await showDialog<bool>(
    context: c,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: C.red, foregroundColor: Colors.white, minimumSize: const Size(88, 44)),
          onPressed: () => Navigator.pop(c, true),
          child: Text(confirm),
        ),
      ],
    ),
  );
  return r ?? false;
}

/// Loading skeleton / error with retry / data builder for any AsyncValue.
class AsyncBody<T> extends StatelessWidget {
  const AsyncBody({super.key, required this.value, required this.builder, this.onRetry, this.skeletonHeight = 96});
  final AsyncValue<T> value;
  final Widget Function(T data) builder;
  final VoidCallback? onRetry;
  final double skeletonHeight;

  @override
  Widget build(BuildContext context) => value.when(
        data: builder,
        loading: () => Column(children: List.generate(3, (_) => Padding(padding: const EdgeInsets.only(bottom: 12), child: Skeleton(height: skeletonHeight)))),
        error: (e, _) => ErrorState(message: errorText(e), onRetry: onRetry, offline: e is ApiException && e.isNetwork),
      );
}

class Skeleton extends StatefulWidget {
  const Skeleton({super.key, this.height = 80, this.width});
  final double height;
  final double? width;
  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat(reverse: true);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (_, __) => Container(
          height: widget.height,
          width: widget.width,
          decoration: BoxDecoration(
            color: Color.lerp(C.card, C.cardHi, _c.value),
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      );
}

class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.message, this.onRetry, this.offline = false});
  final String message;
  final VoidCallback? onRetry;
  final bool offline;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(offline ? Icons.cloud_off_rounded : Icons.error_outline_rounded, size: 40, color: C.amber),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Retry')),
            ],
          ]),
        ),
      );
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.body, this.action});
  final IconData icon;
  final String title;
  final String body;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 44, color: C.muted),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Text(body, style: const TextStyle(color: C.muted), textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ]),
        ),
      );
}

class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.onTap, this.borderColor});
  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final Color? borderColor;
  @override
  Widget build(BuildContext context) => Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: borderColor ?? C.line)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
      );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 20, 2, 10),
        child: Row(children: [
          Expanded(child: Text(text, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
          if (trailing != null) trailing!,
        ]),
      );
}

/// Labels data provenance so facts, estimates, hypotheses and simulated results are never confused.
enum Provenance { fact, estimate, aiHypothesis, ruleBased, simulated, unverified, demo }

class ProvenanceBadge extends StatelessWidget {
  const ProvenanceBadge(this.kind, {super.key});
  final Provenance kind;
  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (kind) {
      Provenance.fact => ('Your record', C.emerald, Icons.check_circle_outline),
      Provenance.estimate => ('Your estimate', C.amber, Icons.edit_note),
      Provenance.aiHypothesis => ('AI hypothesis', C.blue, Icons.auto_awesome),
      Provenance.ruleBased => ('Rule-based demo fallback · not live AI', C.amber, Icons.rule),
      Provenance.simulated => ('Simulated result', C.blue, Icons.calculate_outlined),
      Provenance.unverified => ('Unverified', C.amber, Icons.help_outline),
      Provenance.demo => ('Synthetic demo data', C.amber, Icons.science_outlined),
    };
    return Semantics(
      label: label,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8), border: Border.all(color: color.withValues(alpha: 0.4))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Flexible(child: Text(label, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600))),
        ]),
      ),
    );
  }
}

class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key});
  final String status; // actual | scheduled | estimated | hypothetical
  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'actual' => C.emerald,
      'scheduled' => C.blue,
      'estimated' => C.amber,
      _ => const Color(0xFFC792EA),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(6)),
      child: Text(status, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }
}

Color balanceColor(int minor) => minor < 0 ? C.red : C.text;

/// Projected balance chart. Values are minor units; the zero line is always shown; negative areas are red.
class BalanceChart extends StatelessWidget {
  const BalanceChart({super.key, required this.daily, required this.currency, this.compare, this.height = 190, this.compareLabel});
  final List<Json> daily;
  final List<Json>? compare;
  final String? compareLabel;
  final Currency currency;
  final double height;

  List<FlSpot> _spots(List<Json> d) => [for (var i = 0; i < d.length; i++) FlSpot(i.toDouble(), (d[i]['closing_minor'] as int) / math.pow(10, currency.exponent))];

  @override
  Widget build(BuildContext context) {
    if (daily.isEmpty) return SizedBox(height: height, child: const Center(child: Text('No projection yet', style: TextStyle(color: C.muted))));
    final a = _spots(daily);
    final b = compare == null ? null : _spots(compare!);
    final all = [...a, ...?b].map((s) => s.y);
    var minY = math.min(0.0, all.reduce(math.min));
    var maxY = math.max(0.0, all.reduce(math.max));
    final pad = (maxY - minY).abs() * 0.12 + 1;
    minY -= pad;
    maxY += pad;
    LineChartBarData line(List<FlSpot> s, Color c, {bool dashed = false}) => LineChartBarData(
          spots: s,
          isCurved: false,
          barWidth: 2.5,
          color: c,
          dotData: const FlDotData(show: false),
          dashArray: dashed ? [6, 4] : null,
        );
    // Red fill only where the projected balance is below zero (line clipped at 0, hidden).
    LineChartBarData negArea(List<FlSpot> s) => LineChartBarData(
          spots: [for (final p in s) FlSpot(p.x, math.min(p.y, 0))],
          barWidth: 0,
          color: Colors.transparent,
          dotData: const FlDotData(show: false),
          belowBarData: BarAreaData(show: true, color: C.red.withValues(alpha: 0.22), cutOffY: 0, applyCutOffY: true),
        );
    final primaryColor = b == null ? (a.any((s) => s.y < 0) ? C.amber : C.emerald) : C.muted;
    return Semantics(
      label: 'Projected cash balance chart',
      child: SizedBox(
        height: height,
        child: LineChart(LineChartData(
          minY: minY,
          maxY: maxY,
          gridData: FlGridData(show: true, drawVerticalLine: false, getDrawingHorizontalLine: (_) => const FlLine(color: C.line, strokeWidth: 0.5)),
          borderData: FlBorderData(show: false),
          extraLinesData: ExtraLinesData(horizontalLines: [HorizontalLine(y: 0, color: C.red.withValues(alpha: 0.7), strokeWidth: 1.2, dashArray: [4, 4])]),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 52,
                getTitlesWidget: (v, m) => v == m.max || v == m.min
                    ? const SizedBox()
                    : Text(currency.format((v * math.pow(10, currency.exponent)).round(), compact: true), style: const TextStyle(fontSize: 10, color: C.muted)),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 22,
                interval: math.max(1, (a.length / 4).floorToDouble()),
                getTitlesWidget: (v, m) {
                  final i = v.toInt();
                  if (i < 0 || i >= daily.length) return const SizedBox();
                  return Padding(padding: const EdgeInsets.only(top: 6), child: Text(fmtDate(daily[i]['date'] as String), style: const TextStyle(fontSize: 10, color: C.muted)));
                },
              ),
            ),
          ),
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (_) => C.cardHi,
              getTooltipItems: (spots) => spots.map<LineTooltipItem?>((s) {
                if (s.barIndex > (compare == null ? 0 : 1)) return null;
                final i = s.x.toInt();
                final src = s.barIndex == 0 ? daily : compare!;
                final minor = src[i]['closing_minor'] as int;
                return LineTooltipItem('${fmtDate(src[i]['date'] as String)}\n${currency.format(minor)}', TextStyle(color: minor < 0 ? C.red : C.text, fontSize: 12));
              }).toList(),
            ),
          ),
          lineBarsData: [
            line(a, primaryColor),
            if (b != null) line(b, C.red),
            negArea(b ?? a),
          ],
        )),
      ),
    );
  }
}

class DisclaimerFooter extends StatelessWidget {
  const DisclaimerFooter({super.key});
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Text(kDisclaimer, textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: C.muted)),
      );
}

/// Pull-to-refresh scroll wrapper with consistent padding.
class PageList extends StatelessWidget {
  const PageList({super.key, required this.children, this.onRefresh});
  final List<Widget> children;
  final Future<void> Function()? onRefresh;
  @override
  Widget build(BuildContext context) {
    final list = ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), physics: const AlwaysScrollableScrollPhysics(), children: children);
    return onRefresh == null ? list : RefreshIndicator(onRefresh: onRefresh!, child: list);
  }
}
