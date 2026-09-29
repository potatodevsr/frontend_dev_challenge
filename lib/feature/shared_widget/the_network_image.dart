import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

/// Standard network image with a shimmer placeholder.
class TheNetworkImage extends StatelessWidget {
  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;

  const TheNetworkImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.zero,
      child: LayoutBuilder(builder: (context, constraints) {
        final displayWidth = width != null && width!.isFinite
            ? constraints.constrainWidth(width!)
            : constraints.maxWidth;
        final decodeWidth = displayWidth.isFinite && displayWidth > 0
            ? (displayWidth * MediaQuery.devicePixelRatioOf(context)).ceil()
            : null;
        return CachedNetworkImage(
          // Resize at decode time; keep the original aspect ratio and disk asset.
          memCacheWidth: decodeWidth,
          imageUrl: url,
          width: width,
          height: height,
          fit: fit,
          placeholder: (context, _) => Shimmer.fromColors(
            baseColor: Colors.grey.shade300,
            highlightColor: Colors.grey.shade100,
            child: Container(width: width, height: height, color: Colors.white),
          ),
          errorWidget: (context, _, __) => Container(
            width: width,
            height: height,
            color: Colors.grey.shade200,
            child: const Icon(Icons.image_not_supported_outlined),
          ),
        );
      }),
    );
  }
}
