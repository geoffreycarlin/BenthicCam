import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Satellite / map backgrounds the user can choose between.
enum MapLayer {
  esri(
    'Satellite (Esri World Imagery)',
    'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
    'Esri, Maxar, Earthstar Geographics',
    19,
  ),
  esriClarity(
    'Satellite (Esri Clarity – alternative imagery)',
    'https://clarity.maptiles.arcgis.com/arcgis/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
    'Esri, Maxar, Earthstar Geographics',
    19,
  ),
  nsw(
    'Aerial (NSW Government – NSW only, very accurate)',
    'https://maps.six.nsw.gov.au/arcgis/rest/services/public/NSW_Imagery/MapServer/tile/{z}/{y}/{x}',
    '© Spatial Services NSW (CC BY 4.0)',
    20,
  ),
  osm(
    'Street map (OpenStreetMap)',
    'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    '© OpenStreetMap contributors',
    19,
  );

  final String label;
  final String url;
  final String attribution;
  final int maxNativeZoom;
  const MapLayer(this.label, this.url, this.attribution, this.maxNativeZoom);
}

/// User preferences, remembered between launches.
class AppSettings extends ChangeNotifier {
  final File file;
  AppSettings(this.file);

  bool reviewBeforeSaving = true;
  bool saveToGallery = true;
  bool gpsOnly = false;
  MapLayer mapLayer = MapLayer.esri;

  Future<void> load() async {
    try {
      final j = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      reviewBeforeSaving = j['review'] as bool? ?? reviewBeforeSaving;
      saveToGallery = j['gallery'] as bool? ?? saveToGallery;
      gpsOnly = j['gpsOnly'] as bool? ?? gpsOnly;
      mapLayer = MapLayer.values.asNameMap()[j['map']] ?? mapLayer;
    } catch (_) {/* first run */}
    notifyListeners();
  }

  Future<void> update(void Function(AppSettings s) change) async {
    change(this);
    notifyListeners();
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({
        'review': reviewBeforeSaving,
        'gallery': saveToGallery,
        'gpsOnly': gpsOnly,
        'map': mapLayer.name,
      }));
    } catch (e) {
      debugPrint('Settings not saved: $e');
    }
  }
}
