"""Angle-tolerant, local face-presence lab based on OpenCV YuNet + SFace.

This module is intentionally a no-lock calibration tool. It stores SFace
embeddings and scan metadata, never camera frames or video.
"""

from __future__ import annotations

import argparse
import ctypes
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

try:
    import cv2
    import numpy as np
except ImportError as exc:  # pragma: no cover
    print(f"Face dependencies are missing: {exc}", file=sys.stderr)
    raise SystemExit(20)


WINDOW_NAME = "CA Presence Lab - YuNet + SFace (NO LOCK)"
MAX_LOG_BYTES = 25 * 1024 * 1024
ROTATED_LOGS = 3


class SFaceGuardError(RuntimeError):
    def __init__(self, message: str, exit_code: int) -> None:
        super().__init__(message)
        self.exit_code = exit_code


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def open_camera(index: int):
    backends = [cv2.CAP_DSHOW, cv2.CAP_ANY] if os.name == "nt" else [cv2.CAP_ANY]
    for backend in backends:
        camera = cv2.VideoCapture(index, backend)
        if camera.isOpened():
            camera.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
            camera.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
            return camera
        camera.release()
    raise SFaceGuardError(f"Could not open camera index {index}.", 4)


def create_engines(args):
    yunet_path = Path(args.yunet_model)
    sface_path = Path(args.sface_model)
    if not yunet_path.is_file():
        raise SFaceGuardError(f"YuNet model was not found: {yunet_path}", 5)
    if not sface_path.is_file():
        raise SFaceGuardError(f"SFace model was not found: {sface_path}", 5)
    try:
        cv2.setNumThreads(max(1, int(args.opencv_threads)))
        detector = cv2.FaceDetectorYN_create(
            str(yunet_path),
            "",
            (320, 320),
            float(args.detection_threshold),
            0.3,
            5000,
        )
        recognizer = cv2.FaceRecognizerSF_create(str(sface_path), "")
    except (AttributeError, cv2.error) as exc:
        raise SFaceGuardError(f"Could not load YuNet/SFace: {exc}", 21) from exc
    return detector, recognizer


def detect_faces(detector, frame):
    height, width = frame.shape[:2]
    detector.setInputSize((width, height))
    result = detector.detect(frame)
    faces = result[1] if isinstance(result, tuple) else result
    if faces is None:
        return np.empty((0, 15), dtype=np.float32)
    faces = np.asarray(faces, dtype=np.float32)
    return faces[np.argsort(faces[:, 14])[::-1]]


def face_rectangle(face):
    return tuple(int(round(value)) for value in face[:4])


def measure_quality(frame, face):
    x, y, width, height = face_rectangle(face)
    frame_height, frame_width = frame.shape[:2]
    left = max(0, x)
    top = max(0, y)
    right = min(frame_width, x + width)
    bottom = min(frame_height, y + height)
    if width < 75 or height < 75:
        return False, "move closer", 0.0, 0.0
    region = frame[top:bottom, left:right]
    if region.size == 0:
        return False, "empty face", 0.0, 0.0
    gray = cv2.cvtColor(region, cv2.COLOR_BGR2GRAY)
    brightness = float(np.mean(gray))
    sharpness = float(cv2.Laplacian(gray, cv2.CV_64F).var())
    if brightness < 32:
        return False, "too dark", brightness, sharpness
    if brightness > 228:
        return False, "too bright", brightness, sharpness
    if sharpness < 24:
        return False, "too blurry", brightness, sharpness
    return True, "good", brightness, sharpness


def extract_embedding(recognizer, frame, face):
    try:
        aligned = recognizer.alignCrop(frame, np.asarray(face, dtype=np.float32))
        feature = recognizer.feature(aligned)
    except cv2.error as exc:
        raise SFaceGuardError(f"SFace alignment/feature extraction failed: {exc}", 22) from exc
    vector = np.asarray(feature, dtype=np.float32).reshape(-1)
    norm = float(np.linalg.norm(vector))
    if not np.isfinite(norm) or norm <= 1e-8:
        raise SFaceGuardError("SFace returned an invalid embedding.", 22)
    return vector / norm


def compare_embedding(probe, references):
    similarities = np.matmul(references, probe)
    ordered = np.sort(similarities)[::-1]
    top_count = min(3, len(ordered))
    return float(np.mean(ordered[:top_count])), float(ordered[0])


def prepare_window() -> None:
    cv2.namedWindow(WINDOW_NAME, cv2.WINDOW_NORMAL)
    cv2.resizeWindow(WINDOW_NAME, 760, 620)
    try:
        cv2.setWindowProperty(WINDOW_NAME, cv2.WND_PROP_TOPMOST, 1)
    except cv2.error:
        pass


def set_window_minimized(minimized: bool) -> bool:
    if os.name != "nt":
        return False
    try:
        user32 = ctypes.windll.user32
        handle = user32.FindWindowW(None, WINDOW_NAME)
        if not handle:
            return False
        user32.ShowWindow(handle, 6 if minimized else 9)  # SW_MINIMIZE / SW_RESTORE
        if not minimized:
            user32.SetForegroundWindow(handle)
        return True
    except (AttributeError, OSError):
        return False


def draw_text(frame, text: str, y: int, color=(255, 255, 255), scale=0.65) -> None:
    cv2.putText(frame, text, (18, y), cv2.FONT_HERSHEY_SIMPLEX, scale, (0, 0, 0), 4, cv2.LINE_AA)
    cv2.putText(frame, text, (18, y), cv2.FONT_HERSHEY_SIMPLEX, scale, color, 2, cv2.LINE_AA)


def pose_for_progress(sample_count: int, target: int):
    progress = sample_count / max(1, target)
    if progress < 1 / 3:
        return "FRONT", "Look straight at the camera"
    if progress < 2 / 3:
        return "LEFT", "Turn your head slightly left"
    return "RIGHT", "Turn your head slightly right"


def write_embeddings(model_path: Path, embeddings, poses) -> None:
    model_path.parent.mkdir(parents=True, exist_ok=True)
    matrix = np.asarray(embeddings, dtype=np.float32)
    pose_array = np.asarray(poses, dtype="U8")
    temporary = model_path.with_name(model_path.name + ".tmp")
    with temporary.open("wb") as stream:
        np.savez_compressed(stream, embeddings=matrix, poses=pose_array)
    os.replace(temporary, model_path)

    metadata = {
        "schemaVersion": 1,
        "algorithm": "OpenCV-YuNet-SFace",
        "opencvVersion": cv2.__version__,
        "enrolledUtc": utc_now(),
        "sampleCount": len(embeddings),
        "poses": {pose: poses.count(pose) for pose in sorted(set(poses))},
        "rawImagesStored": False,
    }
    metadata_path = model_path.with_suffix(model_path.suffix + ".json")
    metadata_temp = metadata_path.with_name(metadata_path.name + ".tmp")
    metadata_temp.write_text(json.dumps(metadata, indent=2), encoding="utf-8")
    os.replace(metadata_temp, metadata_path)


def load_embeddings(model_path: Path):
    if not model_path.is_file():
        raise SFaceGuardError(f"SFace enrollment was not found: {model_path}", 5)
    try:
        with np.load(model_path, allow_pickle=False) as payload:
            embeddings = np.asarray(payload["embeddings"], dtype=np.float32)
    except (OSError, KeyError, ValueError) as exc:
        raise SFaceGuardError(f"Could not read SFace enrollment: {exc}", 5) from exc
    if embeddings.ndim != 2 or embeddings.shape[0] < 3:
        raise SFaceGuardError("SFace enrollment contains too few embeddings.", 5)
    norms = np.linalg.norm(embeddings, axis=1, keepdims=True)
    return embeddings / np.maximum(norms, 1e-8)


def enroll(args) -> int:
    detector, recognizer = create_engines(args)
    camera = open_camera(args.camera_index)
    embeddings = []
    poses = []
    started = time.monotonic()
    last_capture = 0.0
    prepare_window()
    try:
        while time.monotonic() - started < args.timeout:
            ok, frame = camera.read()
            if not ok or frame is None:
                raise SFaceGuardError("The camera stopped returning frames.", 4)
            faces = detect_faces(detector, frame)
            display = cv2.flip(frame, 1)
            pose, prompt = pose_for_progress(len(embeddings), args.samples)
            remaining = max(0, int(args.timeout - (time.monotonic() - started)))
            quality_detail = "Show exactly one face"

            if len(faces) == 1:
                face = faces[0]
                quality_ok, reason, brightness, sharpness = measure_quality(frame, face)
                x, y, width, height = face_rectangle(face)
                mirrored_x = frame.shape[1] - x - width
                box_color = (0, 220, 0) if quality_ok else (0, 180, 255)
                cv2.rectangle(display, (mirrored_x, y), (mirrored_x + width, y + height), box_color, 2)
                quality_detail = f"{reason}: light={brightness:.0f}, sharp={sharpness:.0f}"
                now = time.monotonic()
                if quality_ok and now - last_capture >= args.sample_interval:
                    embeddings.append(extract_embedding(recognizer, frame, face))
                    poses.append(pose)
                    last_capture = now
            elif len(faces) > 1:
                quality_detail = "Only the owner should be visible"

            draw_text(display, f"SFace enrollment - {prompt}", 34)
            draw_text(display, f"Samples: {len(embeddings)}/{args.samples}   Time: {remaining}s", 64)
            draw_text(display, quality_detail, 94, (210, 210, 210))
            draw_text(display, "Esc cancels - raw images are not saved", display.shape[0] - 18, (190, 190, 190))
            cv2.imshow(WINDOW_NAME, display)

            if len(embeddings) >= args.samples:
                write_embeddings(Path(args.model), embeddings, poses)
                return 0
            if cv2.waitKey(1) & 0xFF == 27:
                return 12
        return 6
    finally:
        camera.release()
        cv2.destroyAllWindows()


def save_profile(args, threshold: float) -> None:
    if not args.profile:
        return
    profile_path = Path(args.profile)
    profile_path.parent.mkdir(parents=True, exist_ok=True)
    profile = {
        "schemaVersion": 1,
        "engine": "OpenCV-YuNet-SFace",
        "savedUtc": utc_now(),
        "modelPath": str(Path(args.model).resolve()),
        "cameraIndex": args.camera_index,
        "threshold": threshold,
        "detectionThreshold": args.detection_threshold,
        "intervalSeconds": args.interval,
        "scanSeconds": args.scan_seconds,
        "minimumQualityFrames": args.minimum_quality_frames,
        "requiredMatches": args.required_matches,
        "rawImagesStored": False,
    }
    temporary = profile_path.with_name(profile_path.name + ".tmp")
    temporary.write_text(json.dumps(profile, indent=2), encoding="utf-8")
    os.replace(temporary, profile_path)


def append_event(args, event: dict) -> None:
    if not args.log:
        return
    log_path = Path(args.log)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    if log_path.is_file() and log_path.stat().st_size >= MAX_LOG_BYTES:
        oldest = log_path.with_name(f"{log_path.name}.{ROTATED_LOGS}")
        if oldest.exists():
            oldest.unlink()
        for index in range(ROTATED_LOGS - 1, 0, -1):
            source = log_path.with_name(f"{log_path.name}.{index}")
            destination = log_path.with_name(f"{log_path.name}.{index + 1}")
            if source.exists():
                os.replace(source, destination)
        os.replace(log_path, log_path.with_name(f"{log_path.name}.1"))
    with log_path.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(event, separators=(",", ":"), allow_nan=False) + "\n")


def presence_test(args) -> int:
    references = load_embeddings(Path(args.model))
    detector, recognizer = create_engines(args)
    # Pay the one-time DNN initialization cost before the first timed scan.
    warmup_frame = np.zeros((320, 320, 3), dtype=np.uint8)
    detect_faces(detector, warmup_frame)
    recognizer.feature(np.full((112, 112, 3), 127, dtype=np.uint8))
    threshold = float(args.threshold)
    camera = None
    last_open_attempt = 0.0
    consecutive_read_failures = 0
    status = "STARTING"
    status_color = (105, 105, 105)
    detail = "Opening camera..."
    next_scan = time.monotonic()
    stop_at = time.monotonic() + args.duration_hours * 3600.0 if args.duration_hours > 0 else None
    scan_started = None
    last_evidence = 0.0
    match_votes = []
    aggregate_scores = []
    best_scores = []
    quality_rejections = 0
    detected_frames = 0
    prepare_window()

    def begin_scan(now: float) -> None:
        nonlocal scan_started, last_evidence, match_votes, aggregate_scores, best_scores
        nonlocal quality_rejections, detected_frames, status, status_color, detail
        scan_started = now
        last_evidence = 0.0
        match_votes = []
        aggregate_scores = []
        best_scores = []
        quality_rejections = 0
        detected_frames = 0
        status = "SCANNING"
        status_color = (210, 130, 30)
        detail = "Aligning landmarks and collecting independent frames..."

    def finish_scan(now: float) -> None:
        nonlocal scan_started, next_scan, status, status_color, detail
        quality_frames = len(match_votes)
        matches = sum(match_votes)
        ratio = matches / quality_frames if quality_frames else 0.0
        median_similarity = float(np.median(aggregate_scores)) if aggregate_scores else None
        best_similarity = float(max(best_scores)) if best_scores else None

        if quality_frames < args.minimum_quality_frames:
            status = "UNCERTAIN"
            status_color = (0, 165, 255)
            detail = (
                f"Not enough good frames ({quality_frames}/{args.minimum_quality_frames}); "
                f"face={detected_frames}, rejected={quality_rejections}"
            )
        elif matches >= args.required_matches and ratio >= args.owner_ratio:
            status = "OWNER VERIFIED"
            status_color = (0, 165, 0)
            detail = f"matches={matches}/{quality_frames}, median similarity={median_similarity:.3f}"
        elif ratio <= args.other_ratio:
            status = "NOT OWNER"
            status_color = (0, 0, 220)
            detail = f"matches={matches}/{quality_frames}, median similarity={median_similarity:.3f}"
        else:
            status = "UNCERTAIN"
            status_color = (0, 165, 255)
            detail = f"mixed: matches={matches}/{quality_frames}, median similarity={median_similarity:.3f}"

        append_event(
            args,
            {
                "timestampUtc": utc_now(),
                "engine": "OpenCV-YuNet-SFace",
                "status": status,
                "cameraIndex": args.camera_index,
                "threshold": threshold,
                "detectionThreshold": args.detection_threshold,
                "qualityFrames": quality_frames,
                "matches": matches,
                "matchRatio": round(ratio, 4),
                "medianSimilarity": round(median_similarity, 4) if median_similarity is not None else None,
                "bestSimilarity": round(best_similarity, 4) if best_similarity is not None else None,
                "detectedFrames": detected_frames,
                "qualityRejectedFrames": quality_rejections,
                "detail": detail,
                "noLock": True,
            },
        )

        scheduled_from = scan_started if scan_started is not None else now
        scan_started = None
        # The interval is measured start-to-start, so "10 seconds" really means
        # one scan begins every 10 seconds rather than 10 seconds after a scan ends.
        next_scan = max(now, scheduled_from + args.interval)

    try:
        while True:
            now = time.monotonic()
            if stop_at is not None and now >= stop_at:
                return 0
            if camera is None and now - last_open_attempt >= args.camera_retry_seconds:
                last_open_attempt = now
                try:
                    camera = open_camera(args.camera_index)
                    consecutive_read_failures = 0
                    detail = "Camera ready; allowing a 2-second sensor warm-up."
                    next_scan = now + 2.0
                except SFaceGuardError as exc:
                    status = "CAMERA ERROR"
                    status_color = (105, 105, 105)
                    detail = str(exc)

            if camera is not None and scan_started is None and now >= next_scan:
                begin_scan(now)

            frame = np.zeros((480, 640, 3), dtype=np.uint8)
            faces = np.empty((0, 15), dtype=np.float32)
            if camera is not None:
                ok, captured = camera.read()
                if ok and captured is not None:
                    frame = captured
                    consecutive_read_failures = 0
                    # Keep the camera warm, but run the neural detector only
                    # during the 3-second scan window to reduce idle CPU use.
                    if scan_started is not None:
                        faces = detect_faces(detector, frame)
                else:
                    consecutive_read_failures += 1
                    if consecutive_read_failures >= 5:
                        camera.release()
                        camera = None
                        scan_started = None
                        status = "CAMERA ERROR"
                        status_color = (105, 105, 105)
                        detail = "Camera stopped returning frames; retrying automatically."

            now = time.monotonic()
            live_similarity = None
            quality_reason = "no face"
            if len(faces) == 1:
                face = faces[0]
                quality_ok, quality_reason, brightness, sharpness = measure_quality(frame, face)
                x, y, width, height = face_rectangle(face)
                mirrored_x = frame.shape[1] - x - width
                box_color = (0, 220, 0) if quality_ok else (0, 180, 255)
                cv2.rectangle(frame, (x, y), (x + width, y + height), box_color, 2)

                if scan_started is not None:
                    detected_frames += 1
                    if quality_ok and now - last_evidence >= args.sample_interval:
                        try:
                            probe = extract_embedding(recognizer, frame, face)
                            aggregate, best = compare_embedding(probe, references)
                            live_similarity = aggregate
                            aggregate_scores.append(aggregate)
                            best_scores.append(best)
                            match_votes.append(bool(aggregate >= threshold))
                            last_evidence = now
                        except SFaceGuardError:
                            quality_rejections += 1
                    elif not quality_ok:
                        quality_rejections += 1
            elif len(faces) > 1:
                quality_reason = "multiple faces"

            if scan_started is not None and now - scan_started >= args.scan_seconds:
                finish_scan(now)

            display = cv2.flip(frame, 1)
            panel_height = 165
            display = cv2.copyMakeBorder(display, 0, panel_height, 0, 0, cv2.BORDER_CONSTANT, value=(25, 25, 25))
            panel_top = display.shape[0] - panel_height
            cv2.rectangle(display, (18, panel_top + 12), (display.shape[1] - 18, panel_top + 70), status_color, -1)
            text_size = cv2.getTextSize(status, cv2.FONT_HERSHEY_SIMPLEX, 0.9, 2)[0]
            text_x = max(26, (display.shape[1] - text_size[0]) // 2)
            cv2.putText(display, status, (text_x, panel_top + 50), cv2.FONT_HERSHEY_SIMPLEX, 0.9, (255, 255, 255), 2, cv2.LINE_AA)

            if scan_started is None:
                timing = f"Next scan: {max(0, int(round(next_scan - now)))}s"
            else:
                remaining = max(0, args.scan_seconds - (now - scan_started))
                timing = f"Scan: {remaining:.1f}s  votes={sum(match_votes)}/{len(match_votes)}"
            live = f"  live similarity={live_similarity:.3f}" if live_similarity is not None else ""
            draw_text(display, f"{timing}  threshold={threshold:.2f}{live}", panel_top + 96)
            draw_text(display, detail[:92], panel_top + 123, (210, 210, 210), 0.56)
            draw_text(display, "Space=scan   +/-=threshold   S=save   Esc=quit   NO LOCK", panel_top + 151, (170, 170, 170), 0.56)
            cv2.imshow(WINDOW_NAME, display)

            key = cv2.waitKey(1) & 0xFF
            if key in (27, ord("q"), ord("Q")):
                return 0
            if key == 32 and camera is not None:
                begin_scan(now)
            elif key in (ord("+"), ord("=")):
                threshold = min(0.90, threshold + 0.02)
                detail = f"Threshold {threshold:.2f}; higher is stricter."
            elif key in (ord("-"), ord("_")):
                threshold = max(0.10, threshold - 0.02)
                detail = f"Threshold {threshold:.2f}; lower is more permissive."
            elif key in (ord("s"), ord("S")):
                save_profile(args, threshold)
                detail = f"SFace profile saved with threshold {threshold:.2f}."
    finally:
        if camera is not None:
            camera.release()
        cv2.destroyAllWindows()


def evaluate_adaptive_frame(detector, recognizer, references, frame, threshold: float):
    """Process exactly one camera frame and return a compact in-memory result."""
    faces = detect_faces(detector, frame)
    result = {
        "kind": "no_face",
        "similarity": None,
        "bestSimilarity": None,
        "face": None,
        "quality": "no face",
        "matched": False,
    }
    if len(faces) == 0:
        return result
    if len(faces) > 1:
        result["kind"] = "multiple_faces"
        result["quality"] = "multiple faces"
        return result

    face = faces[0]
    quality_ok, reason, brightness, sharpness = measure_quality(frame, face)
    result["face"] = face
    result["quality"] = reason
    result["brightness"] = brightness
    result["sharpness"] = sharpness
    if not quality_ok:
        result["kind"] = "quality_rejected"
        return result

    try:
        probe = extract_embedding(recognizer, frame, face)
        similarity, best = compare_embedding(probe, references)
    except SFaceGuardError:
        result["kind"] = "quality_rejected"
        result["quality"] = "alignment failed"
        return result
    result["kind"] = "owner" if similarity >= threshold else "mismatch"
    result["similarity"] = similarity
    result["bestSimilarity"] = best
    result["matched"] = bool(similarity >= threshold)
    return result


def save_adaptive_profile(args, threshold: float) -> None:
    if not args.profile:
        return
    profile_path = Path(args.profile)
    profile_path.parent.mkdir(parents=True, exist_ok=True)
    profile = {
        "schemaVersion": 2,
        "engine": "OpenCV-YuNet-SFace-Adaptive",
        "savedUtc": utc_now(),
        "modelPath": str(Path(args.model).resolve()),
        "cameraIndex": args.camera_index,
        "threshold": threshold,
        "detectionThreshold": args.detection_threshold,
        "baselineSeconds": args.baseline_seconds,
        "cautiousSeconds": args.cautious_seconds,
        "warningAfterSeconds": args.warning_after_seconds,
        "burstIntervalSeconds": args.burst_interval_seconds,
        "burstSamples": args.burst_samples,
        "recoveryMatches": args.recovery_matches,
        "stableMargin": args.stable_margin,
        "rawImagesStored": False,
    }
    temporary = profile_path.with_name(profile_path.name + ".tmp")
    temporary.write_text(json.dumps(profile, indent=2), encoding="utf-8")
    os.replace(temporary, profile_path)


def adaptive_presence_test(args) -> int:
    """Spread inference over time and escalate only after sustained weak evidence."""
    references = load_embeddings(Path(args.model))
    detector, recognizer = create_engines(args)
    detect_faces(detector, np.zeros((320, 320, 3), dtype=np.uint8))
    recognizer.feature(np.full((112, 112, 3), 127, dtype=np.uint8))

    threshold = float(args.threshold)
    stable_threshold = min(0.95, threshold + args.stable_margin)
    camera = None
    last_open_attempt = 0.0
    consecutive_read_failures = 0
    stop_at = time.monotonic() + args.duration_hours * 3600.0 if args.duration_hours > 0 else None
    next_process = time.monotonic()
    mode = "BASELINE"
    concern_started = None
    burst_results = []
    status = "STARTING"
    status_color = (105, 105, 105)
    detail = "Opening camera..."
    last_result = None
    last_box_until = 0.0
    stable_sample_count = 0
    minimize_pending = bool(args.start_minimized)
    prepare_window()

    def log_result(event_status: str, now_result=None, extra=None) -> None:
        event = {
            "timestampUtc": utc_now(),
            "engine": "OpenCV-YuNet-SFace-Adaptive",
            "status": event_status,
            "mode": mode,
            "cameraIndex": args.camera_index,
            "threshold": threshold,
            "stableThreshold": stable_threshold,
            "baselineSeconds": args.baseline_seconds,
            "noLock": True,
        }
        if now_result is not None:
            event.update(
                {
                    "sampleKind": now_result["kind"],
                    "similarity": (
                        round(float(now_result["similarity"]), 4)
                        if now_result["similarity"] is not None
                        else None
                    ),
                    "bestSimilarity": (
                        round(float(now_result["bestSimilarity"]), 4)
                        if now_result["bestSimilarity"] is not None
                        else None
                    ),
                    "quality": now_result["quality"],
                }
            )
        if extra:
            event.update(extra)
        append_event(args, event)

    def begin_warning(now: float) -> None:
        nonlocal mode, burst_results, next_process, status, status_color, detail
        mode = "BURST"
        burst_results = []
        next_process = now
        status = "WARNING - LOOK AT CAMERA"
        status_color = (0, 80, 230)
        detail = f"Weak evidence for {args.warning_after_seconds:.0f}s; collecting up to {args.burst_samples} confirmations."
        log_result("WARNING_STARTED", last_result)

    def finish_warning(now: float, recovered_early: bool = False) -> None:
        nonlocal mode, concern_started, next_process, status, status_color, detail
        quality_results = [item for item in burst_results if item["similarity"] is not None]
        similarities = [float(item["similarity"]) for item in quality_results]
        matches = sum(bool(item["matched"]) for item in quality_results)
        quality_frames = len(quality_results)
        ratio = matches / quality_frames if quality_frames else 0.0
        median_similarity = float(np.median(similarities)) if similarities else None
        no_face = sum(item["kind"] == "no_face" for item in burst_results)
        rejected = sum(item["kind"] in ("quality_rejected", "multiple_faces") for item in burst_results)

        if recovered_early or (
            quality_frames >= args.minimum_burst_quality
            and matches >= args.minimum_burst_matches
            and ratio >= args.owner_ratio
        ):
            decision = "OWNER VERIFIED"
            status = decision
            status_color = (0, 165, 0)
            detail = f"Recovered: matches={matches}/{quality_frames}; returning to 2-second sampling."
        elif no_face >= max(1, int(np.ceil(args.burst_samples * 0.8))):
            decision = "NO FACE"
            status = decision
            status_color = (0, 165, 255)
            detail = f"No face in {no_face}/{len(burst_results)} confirmations; NO LOCK in lab."
        elif (
            quality_frames >= args.minimum_other_quality
            and ratio <= args.other_ratio
            and median_similarity is not None
            and median_similarity < threshold - args.other_margin
        ):
            decision = "NOT OWNER"
            status = decision
            status_color = (0, 0, 220)
            detail = f"Clear mismatch in lab: matches={matches}/{quality_frames}; NO LOCK."
        else:
            decision = "UNCERTAIN"
            status = decision
            status_color = (0, 165, 255)
            detail = f"No safe decision: good={quality_frames}, no-face={no_face}, rejected={rejected}; NO LOCK."

        log_result(
            decision,
            last_result,
            {
                "attempts": len(burst_results),
                "qualityFrames": quality_frames,
                "matches": matches,
                "matchRatio": round(ratio, 4),
                "medianSimilarity": round(median_similarity, 4) if median_similarity is not None else None,
                "noFaceFrames": no_face,
                "qualityRejectedFrames": rejected,
                "recoveredEarly": recovered_early,
            },
        )
        mode = "BASELINE"
        concern_started = None
        next_process = now + args.baseline_seconds

    try:
        while True:
            now = time.monotonic()
            if stop_at is not None and now >= stop_at:
                return 0
            if camera is None and now - last_open_attempt >= args.camera_retry_seconds:
                last_open_attempt = now
                try:
                    camera = open_camera(args.camera_index)
                    consecutive_read_failures = 0
                    status = "CAMERA WARM-UP"
                    status_color = (105, 105, 105)
                    detail = "Camera ready; first sample in 2 seconds."
                    next_process = now + 2.0
                except SFaceGuardError as exc:
                    status = "CAMERA ERROR"
                    status_color = (105, 105, 105)
                    detail = str(exc)

            frame = np.zeros((480, 640, 3), dtype=np.uint8)
            if camera is not None:
                ok, captured = camera.read()
                if ok and captured is not None:
                    frame = captured
                    consecutive_read_failures = 0
                else:
                    consecutive_read_failures += 1
                    if consecutive_read_failures >= 5:
                        camera.release()
                        camera = None
                        mode = "BASELINE"
                        concern_started = None
                        status = "CAMERA ERROR"
                        status_color = (105, 105, 105)
                        detail = "Camera stopped returning frames; retrying automatically."

            now = time.monotonic()
            if camera is not None and now >= next_process:
                last_result = evaluate_adaptive_frame(detector, recognizer, references, frame, threshold)
                if last_result["face"] is not None:
                    last_box_until = now + 0.8

                if mode == "BURST":
                    burst_results.append(last_result)
                    recent = burst_results[-args.recovery_matches :]
                    recovered = (
                        len(recent) >= args.recovery_matches
                        and all(
                            item["similarity"] is not None
                            and item["similarity"] >= stable_threshold
                            for item in recent
                        )
                    )
                    if recovered:
                        finish_warning(now, recovered_early=True)
                    elif len(burst_results) >= args.burst_samples:
                        finish_warning(now)
                    else:
                        next_process = now + args.burst_interval_seconds
                        status = "WARNING - LOOK AT CAMERA"
                        status_color = (0, 80, 230)
                        detail = (
                            f"Confirmation {len(burst_results)}/{args.burst_samples}: "
                            f"{last_result['kind']}"
                        )
                else:
                    similarity = last_result["similarity"]
                    is_stable = similarity is not None and similarity >= stable_threshold
                    if is_stable:
                        mode = "BASELINE"
                        concern_started = None
                        stable_sample_count += 1
                        status = "OWNER VERIFIED"
                        status_color = (0, 165, 0)
                        detail = f"Stable similarity {similarity:.3f}; next lightweight sample in {args.baseline_seconds:.0f}s."
                        next_process = now + args.baseline_seconds
                        # Keep enough baseline telemetry for calibration without
                        # writing to disk on every healthy two-second sample.
                        if stable_sample_count % args.log_every_stable_samples == 0:
                            log_result("OWNER_SAMPLE", last_result)
                    else:
                        if concern_started is None:
                            concern_started = now
                        mode = "CAUTIOUS"
                        elapsed = now - concern_started
                        status = "CHECKING"
                        status_color = (0, 165, 255)
                        detail = (
                            f"{last_result['kind']} for {elapsed:.1f}/{args.warning_after_seconds:.0f}s; "
                            "sampling once per second."
                        )
                        log_result("WEAK_SAMPLE", last_result)
                        if elapsed >= args.warning_after_seconds:
                            begin_warning(now)
                        else:
                            next_process = now + args.cautious_seconds

            display = cv2.flip(frame, 1)
            if last_result is not None and last_result["face"] is not None and now <= last_box_until:
                x, y, width, height = face_rectangle(last_result["face"])
                mirrored_x = frame.shape[1] - x - width
                color = (0, 220, 0) if last_result["matched"] else (0, 180, 255)
                cv2.rectangle(display, (mirrored_x, y), (mirrored_x + width, y + height), color, 2)

            panel_height = 170
            display = cv2.copyMakeBorder(display, 0, panel_height, 0, 0, cv2.BORDER_CONSTANT, value=(25, 25, 25))
            panel_top = display.shape[0] - panel_height
            cv2.rectangle(display, (18, panel_top + 12), (display.shape[1] - 18, panel_top + 70), status_color, -1)
            text_size = cv2.getTextSize(status, cv2.FONT_HERSHEY_SIMPLEX, 0.82, 2)[0]
            cv2.putText(
                display,
                status,
                (max(26, (display.shape[1] - text_size[0]) // 2), panel_top + 50),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.82,
                (255, 255, 255),
                2,
                cv2.LINE_AA,
            )
            next_in = max(0.0, next_process - now)
            similarity_text = "--"
            if last_result is not None and last_result["similarity"] is not None:
                similarity_text = f"{last_result['similarity']:.3f}"
            draw_text(
                display,
                f"Mode={mode}  next={next_in:.1f}s  similarity={similarity_text}  threshold={threshold:.2f}",
                panel_top + 98,
                scale=0.57,
            )
            draw_text(display, detail[:96], panel_top + 125, (210, 210, 210), 0.55)
            draw_text(
                display,
                "Space=confirm now   +/-=threshold   S=save   Esc=quit   NO LOCK",
                panel_top + 153,
                (170, 170, 170),
                0.54,
            )
            cv2.imshow(WINDOW_NAME, display)

            if minimize_pending and set_window_minimized(True):
                minimize_pending = False

            key = cv2.waitKey(1) & 0xFF
            if key in (27, ord("q"), ord("Q")):
                return 0
            if key == 32 and camera is not None:
                begin_warning(now)
            elif key in (ord("+"), ord("=")):
                threshold = min(0.90, threshold + 0.02)
                stable_threshold = min(0.95, threshold + args.stable_margin)
                detail = f"Threshold {threshold:.2f}; higher is stricter."
            elif key in (ord("-"), ord("_")):
                threshold = max(0.10, threshold - 0.02)
                stable_threshold = min(0.95, threshold + args.stable_margin)
                detail = f"Threshold {threshold:.2f}; lower is more permissive."
            elif key in (ord("s"), ord("S")):
                save_adaptive_profile(args, threshold)
                detail = f"Adaptive profile saved with threshold {threshold:.2f}."
    finally:
        if camera is not None:
            camera.release()
        cv2.destroyAllWindows()


def self_test(args) -> int:
    detector, recognizer = create_engines(args)
    blank = np.zeros((320, 320, 3), dtype=np.uint8)
    detect_faces(detector, blank)
    synthetic_face = np.full((112, 112, 3), 127, dtype=np.uint8)
    feature = np.asarray(recognizer.feature(synthetic_face), dtype=np.float32).reshape(-1)
    if feature.size == 0 or not np.all(np.isfinite(feature)):
        raise SFaceGuardError("SFace model self-test returned an invalid feature.", 23)
    print(json.dumps({"ok": True, "engine": "YuNet+SFace", "opencv": cv2.__version__, "featureSize": int(feature.size)}))
    return 0


def add_engine_arguments(parser) -> None:
    parser.add_argument("--yunet-model", required=True)
    parser.add_argument("--sface-model", required=True)
    parser.add_argument("--detection-threshold", type=float, default=0.75)
    parser.add_argument("--opencv-threads", type=int, default=2)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    self_parser = subparsers.add_parser("self-test")
    add_engine_arguments(self_parser)
    self_parser.set_defaults(handler=self_test)

    enroll_parser = subparsers.add_parser("enroll")
    add_engine_arguments(enroll_parser)
    enroll_parser.add_argument("--model", required=True)
    enroll_parser.add_argument("--camera-index", type=int, default=0)
    enroll_parser.add_argument("--samples", type=int, default=45)
    enroll_parser.add_argument("--sample-interval", type=float, default=0.20)
    enroll_parser.add_argument("--timeout", type=float, default=100.0)
    enroll_parser.set_defaults(handler=enroll)

    presence_parser = subparsers.add_parser("presence-test")
    add_engine_arguments(presence_parser)
    presence_parser.add_argument("--model", required=True)
    presence_parser.add_argument("--profile")
    presence_parser.add_argument("--log")
    presence_parser.add_argument("--camera-index", type=int, default=0)
    presence_parser.add_argument("--threshold", type=float, default=0.45)
    presence_parser.add_argument("--interval", type=float, default=10.0)
    presence_parser.add_argument("--scan-seconds", type=float, default=3.0)
    presence_parser.add_argument("--sample-interval", type=float, default=0.18)
    presence_parser.add_argument("--minimum-quality-frames", type=int, default=6)
    presence_parser.add_argument("--required-matches", type=int, default=4)
    presence_parser.add_argument("--owner-ratio", type=float, default=0.60)
    presence_parser.add_argument("--other-ratio", type=float, default=0.20)
    presence_parser.add_argument("--camera-retry-seconds", type=float, default=3.0)
    presence_parser.add_argument("--duration-hours", type=float, default=0.0)
    presence_parser.set_defaults(handler=presence_test)

    adaptive_parser = subparsers.add_parser("adaptive-test")
    add_engine_arguments(adaptive_parser)
    adaptive_parser.add_argument("--model", required=True)
    adaptive_parser.add_argument("--profile")
    adaptive_parser.add_argument("--log")
    adaptive_parser.add_argument("--camera-index", type=int, default=0)
    adaptive_parser.add_argument("--threshold", type=float, default=0.45)
    adaptive_parser.add_argument("--baseline-seconds", type=float, default=2.0)
    adaptive_parser.add_argument("--cautious-seconds", type=float, default=1.0)
    adaptive_parser.add_argument("--warning-after-seconds", type=float, default=6.0)
    adaptive_parser.add_argument("--burst-interval-seconds", type=float, default=0.5)
    adaptive_parser.add_argument("--burst-samples", type=int, default=10)
    adaptive_parser.add_argument("--recovery-matches", type=int, default=3)
    adaptive_parser.add_argument("--stable-margin", type=float, default=0.08)
    adaptive_parser.add_argument("--minimum-burst-quality", type=int, default=5)
    adaptive_parser.add_argument("--minimum-burst-matches", type=int, default=3)
    adaptive_parser.add_argument("--owner-ratio", type=float, default=0.60)
    adaptive_parser.add_argument("--minimum-other-quality", type=int, default=7)
    adaptive_parser.add_argument("--other-ratio", type=float, default=0.20)
    adaptive_parser.add_argument("--other-margin", type=float, default=0.04)
    adaptive_parser.add_argument("--log-every-stable-samples", type=int, default=10)
    adaptive_parser.add_argument("--camera-retry-seconds", type=float, default=3.0)
    adaptive_parser.add_argument("--duration-hours", type=float, default=0.0)
    adaptive_parser.add_argument("--start-minimized", action="store_true")
    adaptive_parser.set_defaults(handler=adaptive_presence_test)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        return int(args.handler(args))
    except SFaceGuardError as exc:
        print(str(exc), file=sys.stderr)
        return exc.exit_code
    except KeyboardInterrupt:
        return 12


if __name__ == "__main__":
    raise SystemExit(main())
