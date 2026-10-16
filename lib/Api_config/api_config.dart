/// Central place for every endpoint used by the BA module.
class ApiConfig {
  static const String base = 'http://tapex.mezangrp.com/ords/hrms/ba-sales-v2';

  static const String locations = '$base/locations/list/';
  static const String signup = '$base/auth/signup/';
  static const String login = '$base/auth/login/';
  static const String profile = '$base/auth/profile/';
  static const String attendanceIn = '$base/auth/attendance-in/';
  static const String attendanceOut = '$base/auth/attendance-out/';
  static const String skuList = '$base/sku/list/';

  /// NOTE: no trailing slash here - matches your curl exactly.
  static const String enterSales = '$base/enter_sales';

  static const Duration timeout = Duration(seconds: 30);
}
