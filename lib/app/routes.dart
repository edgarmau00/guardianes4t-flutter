import 'package:flutter/material.dart';

import '../features/auth/login_screen.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/capture/capture_menu_screen.dart';
import '../features/capture/ocr_review_screen.dart';
import '../features/capture/promoted_form_screen.dart';
import '../features/capture/scan_ine_screen.dart';
import '../features/leaders/leader_detail_screen.dart';
import '../features/leaders/leader_form_screen.dart';
import '../features/lists/leaders_list_screen.dart';
import '../features/lists/promoted_list_screen.dart';
import '../features/whatsapp/whatsapp_broadcast_screen.dart';
import '../features/whatsapp/whatsapp_group_form_screen.dart';
import '../features/whatsapp/whatsapp_groups_screen.dart';

class AppRoutes {
  static const login = '/';
  static const dashboard = '/dashboard';
  static const captureMenu = '/capture-menu';
  static const scanIne = '/scan-ine';
  static const ocrReview = '/ocr-review';
  static const promotedForm = '/promoted-form';
  static const leaderForm = '/leader-form';
  static const leaderDetail = '/leader-detail';
  static const promotedList = '/promoted-list';
  static const leadersList = '/leaders-list';
  static const whatsappGroups = '/whatsapp-groups';
  static const whatsappGroupForm = '/whatsapp-group-form';
  static const whatsappBroadcast = '/whatsapp-broadcast';

  static final routes = <String, WidgetBuilder>{
    login: (_) => const LoginScreen(),
    dashboard: (_) => const DashboardScreen(),
    captureMenu: (_) => const CaptureMenuScreen(),
    scanIne: (_) => const ScanIneScreen(),
    ocrReview: (_) => const OcrReviewScreen(),
    promotedForm: (_) => const PromotedFormScreen(),
    leaderForm: (_) => const LeaderFormScreen(),
    leaderDetail: (_) => const LeaderDetailScreen(),
    promotedList: (_) => const PromotedListScreen(),
    leadersList: (_) => const LeadersListScreen(),
    whatsappGroups: (_) => const WhatsappGroupsScreen(),
    whatsappGroupForm: (_) => const WhatsappGroupFormScreen(),
    whatsappBroadcast: (_) => const WhatsappBroadcastScreen(),
  };
}
