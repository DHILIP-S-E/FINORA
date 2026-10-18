/// Currency abstraction. Money is always integer minor units (never double).
class Currency {
  const Currency(this.code, this.symbol, this.exponent, {this.lakhGrouping = false});
  final String code;
  final String symbol;
  final int exponent;
  final bool lakhGrouping;

  static const inr = Currency('INR', '₹', 2, lakhGrouping: true);
  static const usd = Currency('USD', r'$', 2);
  static const eur = Currency('EUR', '€', 2);
  static const gbp = Currency('GBP', '£', 2);
  static const all = [inr, usd, eur, gbp];

  static Currency of(String? code) => all.firstWhere((c) => c.code == code, orElse: () => inr);

  /// Format minor units, e.g. 12345678 -> ₹1,23,456.78 (INR) or $123,456.78.
  String format(int minor, {bool compact = false, bool showSign = false}) {
    final neg = minor < 0;
    final abs = minor.abs();
    final div = _pow10(exponent);
    var whole = (abs ~/ div).toString();
    final frac = exponent == 0 ? '' : (abs % div).toString().padLeft(exponent, '0');
    if (compact && abs >= 100000 * div && lakhGrouping) {
      final v = abs / (100000 * div);
      return '${neg ? '-' : ''}$symbol${v.toStringAsFixed(v >= 100 ? 0 : 1)}L';
    }
    if (compact && abs >= 1000 * div) {
      final v = abs / (1000 * div);
      return '${neg ? '-' : ''}$symbol${v.toStringAsFixed(v >= 100 ? 0 : 1)}k';
    }
    whole = lakhGrouping ? _lakh(whole) : _western(whole);
    final body = exponent == 0 ? whole : '$whole.$frac';
    final sign = neg ? '-' : (showSign && minor > 0 ? '+' : '');
    return '$sign$symbol$body';
  }

  /// Parse user input like "12,500.50" to minor units without floating point. Returns null if invalid.
  int? parse(String input) {
    final s = input.trim().replaceAll(',', '').replaceAll(symbol, '');
    final m = RegExp(r'^(-?)(\d+)(?:\.(\d*))?$').firstMatch(s);
    if (m == null) return null;
    final frac = m.group(3) ?? '';
    if (frac.length > exponent) return null;
    final minor = int.parse(m.group(2)!) * _pow10(exponent) + (frac.isEmpty ? 0 : int.parse(frac.padRight(exponent, '0')));
    if (minor > 10000000000000) return null;
    return m.group(1) == '-' ? -minor : minor;
  }

  /// Plain decimal string for editing, e.g. 1250050 -> "12500.50".
  String plain(int minor) {
    final neg = minor < 0;
    final abs = minor.abs();
    final div = _pow10(exponent);
    final w = abs ~/ div;
    return '${neg ? '-' : ''}$w${exponent == 0 ? '' : '.${(abs % div).toString().padLeft(exponent, '0')}'}';
  }

  static int _pow10(int e) {
    var r = 1;
    for (var i = 0; i < e; i++) {
      r *= 10;
    }
    return r;
  }

  static String _western(String d) => d.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

  static String _lakh(String d) {
    if (d.length <= 3) return d;
    final last3 = d.substring(d.length - 3);
    var rest = d.substring(0, d.length - 3);
    final parts = <String>[];
    while (rest.length > 2) {
      parts.insert(0, rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) parts.insert(0, rest);
    return '${parts.join(',')},$last3';
  }
}
