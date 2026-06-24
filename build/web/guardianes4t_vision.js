(function () {
  const targetAspect = 1.58;

  function orderPoints(points) {
    const bySum = [...points].sort((a, b) => (a.x + a.y) - (b.x + b.y));
    const byDiff = [...points].sort((a, b) => (a.y - a.x) - (b.y - b.x));

    const topLeft = bySum[0];
    const bottomRight = bySum[bySum.length - 1];
    const topRight = byDiff[0];
    const bottomLeft = byDiff[byDiff.length - 1];

    return [topLeft, topRight, bottomRight, bottomLeft];
  }

  function distance(a, b) {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return Math.sqrt((dx * dx) + (dy * dy));
  }

  function contourToPoints(contour) {
    const points = [];
    for (let i = 0; i < contour.data32S.length; i += 2) {
      points.push({
        x: contour.data32S[i],
        y: contour.data32S[i + 1],
      });
    }
    return points;
  }

  function buildMetrics(canvasWidth, canvasHeight, orderedPoints, area) {
    const widthA = distance(orderedPoints[0], orderedPoints[1]);
    const widthB = distance(orderedPoints[2], orderedPoints[3]);
    const heightA = distance(orderedPoints[1], orderedPoints[2]);
    const heightB = distance(orderedPoints[3], orderedPoints[0]);

    const docWidth = Math.max(widthA, widthB);
    const docHeight = Math.max(heightA, heightB);
    const aspect = docHeight > 0 ? docWidth / docHeight : 0;
    const areaRatio = area / (canvasWidth * canvasHeight);
    const cx = orderedPoints.reduce((sum, p) => sum + p.x, 0) / 4;
    const cy = orderedPoints.reduce((sum, p) => sum + p.y, 0) / 4;
    const centerDistance = Math.sqrt(
      Math.pow((cx / canvasWidth) - 0.5, 2) +
      Math.pow((cy / canvasHeight) - 0.5, 2)
    );

    return {
      aspect,
      areaRatio,
      centerDistance,
      width: docWidth,
      height: docHeight,
    };
  }

  function chooseBestQuad(canvasWidth, canvasHeight, contours) {
    let best = null;
    let bestScore = -9999;

    for (let i = 0; i < contours.size(); i++) {
      const contour = contours.get(i);
      const perimeter = cv.arcLength(contour, true);
      const approx = new cv.Mat();
      cv.approxPolyDP(contour, approx, 0.03 * perimeter, true);

      if (approx.rows === 4) {
        const points = orderPoints(contourToPoints(approx));
        const area = Math.abs(cv.contourArea(approx));
        const metrics = buildMetrics(canvasWidth, canvasHeight, points, area);
        const aspectError = Math.abs(metrics.aspect - targetAspect);
        const convex = cv.isContourConvex(approx);

        if (convex && metrics.areaRatio > 0.12 && metrics.areaRatio < 0.90) {
          const score =
            (metrics.areaRatio * 10) -
            (aspectError * 4) -
            (metrics.centerDistance * 3);

          if (score > bestScore) {
            bestScore = score;
            best = {
              points,
              metrics,
            };
          }
        }
      }

      approx.delete();
      contour.delete();
    }

    return best;
  }

  async function waitForOpenCv(timeoutMs) {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      if (window.cv && typeof window.cv.imread === 'function') {
        return true;
      }
      await new Promise((resolve) => setTimeout(resolve, 120));
    }
    return false;
  }

  async function detectDocument(canvas) {
    const ready = await waitForOpenCv(2500);
    if (!ready) {
      return null;
    }

    let src;
    let gray;
    let blur;
    let edges;
    let kernel;
    let closed;
    let contours;
    let hierarchy;

    try {
      src = cv.imread(canvas);
      gray = new cv.Mat();
      blur = new cv.Mat();
      edges = new cv.Mat();
      kernel = cv.getStructuringElement(cv.MORPH_RECT, new cv.Size(5, 5));
      closed = new cv.Mat();
      contours = new cv.MatVector();
      hierarchy = new cv.Mat();

      cv.cvtColor(src, gray, cv.COLOR_RGBA2GRAY, 0);
      cv.GaussianBlur(gray, blur, new cv.Size(5, 5), 0, 0, cv.BORDER_DEFAULT);
      cv.Canny(blur, edges, 60, 160);
      cv.morphologyEx(edges, closed, cv.MORPH_CLOSE, kernel);
      cv.findContours(
        closed,
        contours,
        hierarchy,
        cv.RETR_LIST,
        cv.CHAIN_APPROX_SIMPLE,
      );

      const best = chooseBestQuad(canvas.width, canvas.height, contours);
      if (!best) {
        return null;
      }

      return {
        left: Math.min(...best.points.map((p) => p.x)) / canvas.width,
        top: Math.min(...best.points.map((p) => p.y)) / canvas.height,
        right: Math.max(...best.points.map((p) => p.x)) / canvas.width,
        bottom: Math.max(...best.points.map((p) => p.y)) / canvas.height,
        points: best.points.map((p) => ({
          x: p.x / canvas.width,
          y: p.y / canvas.height,
        })),
        areaRatio: best.metrics.areaRatio,
        aspectRatio: best.metrics.aspect,
        centerDistance: best.metrics.centerDistance,
      };
    } catch (_) {
      return null;
    } finally {
      if (src) src.delete();
      if (gray) gray.delete();
      if (blur) blur.delete();
      if (edges) edges.delete();
      if (kernel) kernel.delete();
      if (closed) closed.delete();
      if (contours) contours.delete();
      if (hierarchy) hierarchy.delete();
    }
  }

  async function cropPerspective(canvas, pointsNormalized) {
    const ready = await waitForOpenCv(2500);
    if (!ready || !pointsNormalized || pointsNormalized.length !== 4) {
      return canvas.toDataURL('image/jpeg', 0.94);
    }

    let src;
    let dst;
    let srcTri;
    let dstTri;
    let transform;
    let outputCanvas;

    try {
      src = cv.imread(canvas);
      const points = pointsNormalized.map((p) => ({
        x: p.x * canvas.width,
        y: p.y * canvas.height,
      }));
      const ordered = orderPoints(points);

      const widthA = distance(ordered[2], ordered[3]);
      const widthB = distance(ordered[1], ordered[0]);
      const heightA = distance(ordered[1], ordered[2]);
      const heightB = distance(ordered[0], ordered[3]);

      const maxWidth = Math.max(320, Math.round(Math.max(widthA, widthB)));
      const maxHeight = Math.max(
        200,
        Math.round(Math.max(heightA, heightB))
      );

      srcTri = cv.matFromArray(4, 1, cv.CV_32FC2, [
        ordered[0].x, ordered[0].y,
        ordered[1].x, ordered[1].y,
        ordered[2].x, ordered[2].y,
        ordered[3].x, ordered[3].y,
      ]);

      dstTri = cv.matFromArray(4, 1, cv.CV_32FC2, [
        0, 0,
        maxWidth - 1, 0,
        maxWidth - 1, maxHeight - 1,
        0, maxHeight - 1,
      ]);

      transform = cv.getPerspectiveTransform(srcTri, dstTri);
      dst = new cv.Mat();
      cv.warpPerspective(
        src,
        dst,
        transform,
        new cv.Size(maxWidth, maxHeight),
        cv.INTER_LINEAR,
        cv.BORDER_CONSTANT,
        new cv.Scalar(),
      );

      outputCanvas = document.createElement('canvas');
      outputCanvas.width = maxWidth;
      outputCanvas.height = maxHeight;
      cv.imshow(outputCanvas, dst);
      return outputCanvas.toDataURL('image/jpeg', 0.95);
    } catch (_) {
      return canvas.toDataURL('image/jpeg', 0.94);
    } finally {
      if (src) src.delete();
      if (dst) dst.delete();
      if (srcTri) srcTri.delete();
      if (dstTri) dstTri.delete();
      if (transform) transform.delete();
    }
  }

  window.Guardianes4TVision = {
    isReady: async () => waitForOpenCv(2500),
    detectDocument,
    cropPerspective,
  };
})();
