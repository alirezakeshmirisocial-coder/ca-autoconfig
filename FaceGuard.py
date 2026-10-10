"""Local, deliberately lightweight face verification for CA Unlock Guard.

This helper never writes camera frames to disk. Enrollment stores only an OpenCV
LBPH model plus non-biometric metadata. It is designed as a household tripwire,
not as spoof-resistant biometric authentication.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from collections import deque
from datetime import datetime, timezone
from pathlib import Path

try:
    import cv2
    import numpy as np
except ImportError as exc:  # pragma: no cover - exercised before dependencies exist
    print(f"Face dependencies are missing: {exc}", file=sys.stderr)
    raise SystemExit(20)


WINDOW_NAME = "CA Guard - Face verification"
FACE_SIZE = (200, 200)


class FaceGuardError(RuntimeError):
    """Expected camera or model failure with a stable process exit code."""

    def __init__(self, message: str, exit_code: int) -> None:
        super().__init__(message)
        self.exit_code = exit_code


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def create_detectors():
    cascade_root = Path(cv2.data.haarcascades)
    frontal_path = cascade_root / "haarcascade_frontalface_default.xml"
    profile_path = cascade_root / "haarcascade_profileface.xml"
    frontal = cv2.CascadeClassifier(str(frontal_path))
    profile = cv2.CascadeClassifier(str(profile_path))
    if frontal.empty() or profile.empty():
        raise FaceGuardError(f"Could not load face detectors from: {cascade_root}", 21)
    return frontal, profile


def create_recognizer(threshold: float):
    if not hasattr(cv2, "face") or not hasattr(cv2.face, "LBPHFaceRecognizer_create"):
        raise FaceGuardError(
            "OpenCV contrib face module is unavailable. Install requirements-face.txt.",
            20,
        )
    return cv2.face.LBPHFaceRecognizer_create(1, 8, 8, 8, threshold)


def open_camera(index: int):
    backends = [cv2.CAP_DSHOW, cv2.CAP_ANY] if os.name == "nt" else [cv2.CAP_ANY]
    for backend in backends:
        camera = cv2.VideoCapture(index, backend)
        if camera.isOpened():
            camera.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
            camera.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
            return camera
        camera.release()
    raise FaceGuardError(f"Could not open camera index {index}.", 4)


def _detect(detector, gray):
    return detector.detectMultiScale(
        gray,
        scaleFactor=1.12,
        minNeighbors=5,
        minSize=(80, 80),
        flags=cv2.CASCADE_SCALE_IMAGE,
    )


def find_faces(detectors, gray):
    """Prefer frontal detection, then try both profile directions."""
    frontal, profile = detectors
    faces = _detect(frontal, gray)
    if len(faces):
        return faces

    faces = _detect(profile, gray)
    if len(faces):
        return faces

    flipped = cv2.flip(gray, 1)
    mirrored_faces = _detect(profile, flipped)
    if not len(mirrored_faces):
        return mirrored_faces

    width = gray.shape[1]
    restored = []
    for x, y, face_width, face_height in mirrored_faces:
        restored.append((width - int(x) - int(face_width), int(y), int(face_width), int(face_height)))
    return np.asarray(restored, dtype=np.int32)


def normalize_face(gray, rectangle):
    x, y, width, height = (int(value) for value in rectangle)
    margin_x = int(width * 0.12)
    margin_y = int(height * 0.15)
    left = max(0, x - margin_x)
    top = max(0, y - margin_y)
    right = min(gray.shape[1], x + width + margin_x)
    bottom = min(gray.shape[0], y + height + margin_y)
    face = gray[top:bottom, left:right]
    if face.size == 0:
        raise FaceGuardError("Detected an empty face region.", 22)
    face = cv2.resize(face, FACE_SIZE, interpolation=cv2.INTER_AREA)
    clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
    return clahe.apply(face)


def measure_quality(gray, rectangle):
    x, y, width, height = (int(value) for value in rectangle)
    region = gray[y : y + height, x : x + width]
    if region.size == 0:
        return False, "empty", 0.0, 0.0
    brightness = float(np.mean(region))
    sharpness = float(cv2.Laplacian(region, cv2.CV_64F).var())
    if brightness < 35:
        return False, "too dark", brightness, sharpness
    if brightness > 225:
        return False, "too bright", brightness, sharpness
    if sharpness < 32:
        return False, "too blurry", brightness, sharpness
    return True, "good", brightness, sharpness


def prepare_window() -> None:
    cv2.namedWindow(WINDOW_NAME, cv2.WINDOW_NORMAL)
    cv2.resizeWindow(WINDOW_NAME, 720, 540)
    try:
        cv2.setWindowProperty(WINDOW_NAME, cv2.WND_PROP_TOPMOST, 1)
    except cv2.error:
        pass


def draw_text(frame, text: str, y: int, color=(255, 255, 255)) -> None:
    cv2.putText(
        frame,
        text,
        (18, y),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.68,
        (0, 0, 0),
        4,
        cv2.LINE_AA,
    )
    cv2.putText(
        frame,
        text,
        (18, y),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.68,
        color,
        2,
        cv2.LINE_AA,
    )


def write_model_atomically(recognizer, model_path: Path, sample_count: int) -> None:
    model_path.parent.mkdir(parents=True, exist_ok=True)
    temporary_model = model_path.with_name(f"{model_path.stem}.tmp{model_path.suffix}")
    recognizer.write(str(temporary_model))
    os.replace(temporary_model, model_path)

    metadata = {
        "schemaVersion": 1,
        "algorithm": "OpenCV-LBPH",
        "opencvVersion": cv2.__version__,
        "enrolledUtc": utc_now(),
        "sampleCount": sample_count,
        "rawImagesStored": False,
    }
    metadata_path = model_path.with_suffix(model_path.suffix + ".json")
    temporary_metadata = metadata_path.with_suffix(metadata_path.suffix + ".tmp")
    temporary_metadata.write_text(json.dumps(metadata, indent=2), encoding="utf-8")
    os.replace(temporary_metadata, metadata_path)


def enroll(args) -> int:
    detectors = create_detectors()
    recognizer = create_recognizer(args.threshold)
    camera = open_camera(args.camera_index)
    samples = []
    labels = []
    started = time.monotonic()
    last_capture = 0.0
    prepare_window()

    try:
        while time.monotonic() - started < args.timeout:
            ok, frame = camera.read()
            if not ok or frame is None:
                raise FaceGuardError("The camera stopped returning frames.", 4)

            gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            faces = find_faces(detectors, gray)
            display = cv2.flip(frame, 1)
            remaining = max(0, int(args.timeout - (time.monotonic() - started)))

            if len(faces) == 1:
                x, y, width, height = (int(value) for value in faces[0])
                mirrored_x = frame.shape[1] - x - width
                quality_ok, quality_reason, brightness, sharpness = measure_quality(gray, faces[0])
                box_color = (0, 220, 0) if quality_ok else (0, 180, 255)
                cv2.rectangle(display, (mirrored_x, y), (mirrored_x + width, y + height), box_color, 2)
                now = time.monotonic()
                if quality_ok and now - last_capture >= args.sample_interval:
                    samples.append(normalize_face(gray, faces[0]))
                    labels.append(1)
                    last_capture = now
                elif not quality_ok:
                    draw_text(
                        display,
                        f"Improve image: {quality_reason} (light {brightness:.0f}, sharp {sharpness:.0f})",
                        94,
                        (0, 180, 255),
                    )
            elif len(faces) > 1:
                draw_text(display, "Only the owner should be visible", 94, (0, 180, 255))

            progress = len(samples) / max(1, args.samples)
            if progress < 0.34:
                pose_prompt = "look straight at the camera"
            elif progress < 0.67:
                pose_prompt = "turn your head slightly left"
            else:
                pose_prompt = "turn your head slightly right"
            draw_text(display, f"Enrollment: {pose_prompt}", 34)
            draw_text(display, f"Samples: {len(samples)}/{args.samples}   Time: {remaining}s", 64)
            draw_text(display, "Esc cancels enrollment", display.shape[0] - 18, (190, 190, 190))
            cv2.imshow(WINDOW_NAME, display)

            if len(samples) >= args.samples:
                recognizer.train(samples, np.asarray(labels, dtype=np.int32))
                write_model_atomically(recognizer, Path(args.model), len(samples))
                return 0
            if cv2.waitKey(1) & 0xFF == 27:
                return 12
        return 6
    finally:
        camera.release()
        cv2.destroyAllWindows()


def verify(args) -> int:
    model_path = Path(args.model)
    if not model_path.is_file():
        raise FaceGuardError(f"Face model was not found: {model_path}", 5)

    detectors = create_detectors()
    recognizer = create_recognizer(args.threshold)
    recognizer.read(str(model_path))
    recognizer.setThreshold(args.threshold)
    camera = open_camera(args.camera_index)
    started = time.monotonic()
    recent_matches = deque(maxlen=args.window_size)
    saw_face = False
    prepare_window()

    try:
        while time.monotonic() - started < args.timeout:
            ok, frame = camera.read()
            if not ok or frame is None:
                raise FaceGuardError("The camera stopped returning frames.", 4)

            gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            faces = find_faces(detectors, gray)
            display = cv2.flip(frame, 1)
            remaining = max(0, int(args.timeout - (time.monotonic() - started)))
            score_text = "No face"
            color = (0, 180, 255)

            if len(faces) == 1:
                saw_face = True
                quality_ok, quality_reason, brightness, sharpness = measure_quality(gray, faces[0])
                if quality_ok:
                    label, confidence = recognizer.predict(normalize_face(gray, faces[0]))
                    matched = label == 1 and confidence <= args.threshold
                    recent_matches.append(bool(matched))
                    score_text = f"Match score: {confidence:.1f} / {args.threshold:.1f}"
                    color = (0, 220, 0) if matched else (0, 0, 255)
                else:
                    recent_matches.append(False)
                    score_text = f"Image quality: {quality_reason} ({brightness:.0f}/{sharpness:.0f})"
                    color = (0, 180, 255)

                x, y, width, height = (int(value) for value in faces[0])
                mirrored_x = frame.shape[1] - x - width
                cv2.rectangle(display, (mirrored_x, y), (mirrored_x + width, y + height), color, 2)
            else:
                recent_matches.append(False)
                if len(faces) > 1:
                    score_text = "Multiple faces detected"

            matches = sum(recent_matches)
            draw_text(display, "CA Guard: owner face required", 34)
            draw_text(display, f"{score_text}   Evidence: {matches}/{args.required_matches}", 64, color)
            draw_text(display, f"Time remaining: {remaining}s   Esc cancels", display.shape[0] - 18)
            cv2.imshow(WINDOW_NAME, display)

            if matches >= args.required_matches:
                return 0
            if cv2.waitKey(1) & 0xFF == 27:
                return 12
        return 3 if saw_face else 6
    finally:
        camera.release()
        cv2.destroyAllWindows()


def save_presence_profile(args, threshold: float) -> None:
    if not args.profile:
        return
    profile_path = Path(args.profile)
    profile_path.parent.mkdir(parents=True, exist_ok=True)
    profile = {
        "schemaVersion": 1,
        "savedUtc": utc_now(),
        "modelPath": str(Path(args.model).resolve()),
        "cameraIndex": args.camera_index,
        "threshold": threshold,
        "intervalSeconds": args.interval,
        "scanSeconds": args.scan_seconds,
        "minimumQualityFrames": args.minimum_quality_frames,
        "requiredMatches": args.required_matches,
        "rawImagesStored": False,
    }
    temporary = profile_path.with_suffix(profile_path.suffix + ".tmp")
    temporary.write_text(json.dumps(profile, indent=2), encoding="utf-8")
    os.replace(temporary, profile_path)


def append_presence_event(args, event: dict) -> None:
    if not args.log:
        return
    log_path = Path(args.log)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(event, separators=(",", ":")) + "\n")


def presence_test(args) -> int:
    """Run a no-lock periodic presence monitor for threshold calibration."""
    model_path = Path(args.model)
    if not model_path.is_file():
        raise FaceGuardError(f"Face model was not found: {model_path}", 5)

    detectors = create_detectors()
    recognizer = create_recognizer(args.threshold)
    recognizer.read(str(model_path))
    threshold = float(args.threshold)
    camera = None
    last_open_attempt = 0.0
    consecutive_read_failures = 0
    status = "STARTING"
    status_color = (105, 105, 105)
    detail = "Opening camera..."
    next_scan = time.monotonic()
    stop_at = time.monotonic() + (args.duration_hours * 3600.0) if args.duration_hours > 0 else None
    scan_started = None
    last_evidence = 0.0
    match_votes = []
    scores = []
    quality_rejections = 0
    detected_faces = 0
    prepare_window()

    def begin_scan(now: float) -> None:
        nonlocal scan_started, last_evidence, match_votes, scores
        nonlocal quality_rejections, detected_faces, status, status_color, detail
        scan_started = now
        last_evidence = 0.0
        match_votes = []
        scores = []
        quality_rejections = 0
        detected_faces = 0
        status = "SCANNING"
        status_color = (210, 130, 30)
        detail = "Collecting several independent frames..."

    def finish_scan(now: float) -> None:
        nonlocal scan_started, next_scan, status, status_color, detail
        quality_frames = len(match_votes)
        matches = sum(match_votes)
        ratio = matches / quality_frames if quality_frames else 0.0
        median_score = float(np.median(scores)) if scores else None

        if quality_frames < args.minimum_quality_frames:
            status = "UNCERTAIN"
            status_color = (0, 165, 255)
            detail = (
                f"Not enough good frames ({quality_frames}/{args.minimum_quality_frames}); "
                f"face={detected_faces}, rejected={quality_rejections}"
            )
        elif matches >= args.required_matches and ratio >= args.owner_ratio:
            status = "OWNER VERIFIED"
            status_color = (0, 165, 0)
            detail = f"matches={matches}/{quality_frames}, median score={median_score:.1f}"
        elif ratio <= args.other_ratio:
            status = "NOT OWNER"
            status_color = (0, 0, 220)
            detail = f"matches={matches}/{quality_frames}, median score={median_score:.1f}"
        else:
            status = "UNCERTAIN"
            status_color = (0, 165, 255)
            detail = f"mixed result: matches={matches}/{quality_frames}, median score={median_score:.1f}"

        append_presence_event(
            args,
            {
                "timestampUtc": utc_now(),
                "status": status,
                "cameraIndex": args.camera_index,
                "threshold": threshold,
                "qualityFrames": quality_frames,
                "matches": matches,
                "matchRatio": round(ratio, 4),
                "medianScore": round(median_score, 3) if median_score is not None else None,
                "detectedFrames": detected_faces,
                "qualityRejectedFrames": quality_rejections,
                "detail": detail,
            },
        )

        scheduled_from = scan_started if scan_started is not None else now
        scan_started = None
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
                    detail = "Camera recovered; waiting for scan."
                    next_scan = now
                except FaceGuardError as exc:
                    status = "CAMERA ERROR"
                    status_color = (105, 105, 105)
                    detail = str(exc)

            frame = np.zeros((480, 640, 3), dtype=np.uint8)
            faces = []
            gray = None
            quality = None
            if camera is not None:
                ok, captured = camera.read()
                if ok and captured is not None:
                    frame = captured
                    consecutive_read_failures = 0
                    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
                    faces = find_faces(detectors, gray)
                    if len(faces) == 1:
                        quality = measure_quality(gray, faces[0])
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
            if camera is not None and scan_started is None and now >= next_scan:
                begin_scan(now)

            score_for_display = None
            quality_reason = "no face"
            if len(faces) == 1 and gray is not None:
                x, y, width, height = (int(value) for value in faces[0])
                mirrored_x = frame.shape[1] - x - width
                quality_ok, quality_reason, brightness, sharpness = quality
                box_color = (0, 220, 0) if quality_ok else (0, 180, 255)
                cv2.rectangle(frame, (x, y), (x + width, y + height), box_color, 2)

                if scan_started is not None:
                    detected_faces += 1
                    if quality_ok and now - last_evidence >= args.sample_interval:
                        recognizer.setThreshold(threshold)
                        label, confidence = recognizer.predict(normalize_face(gray, faces[0]))
                        matched = label == 1 and confidence <= threshold
                        match_votes.append(bool(matched))
                        scores.append(float(confidence))
                        score_for_display = float(confidence)
                        last_evidence = now
                    elif not quality_ok:
                        quality_rejections += 1
            elif len(faces) > 1:
                quality_reason = "multiple faces"

            if scan_started is not None and now - scan_started >= args.scan_seconds:
                finish_scan(now)

            display = cv2.flip(frame, 1)
            panel_height = 150
            display = cv2.copyMakeBorder(display, 0, panel_height, 0, 0, cv2.BORDER_CONSTANT, value=(25, 25, 25))
            panel_top = display.shape[0] - panel_height
            button_left, button_top = 18, panel_top + 14
            button_right, button_bottom = display.shape[1] - 18, panel_top + 72
            cv2.rectangle(display, (button_left, button_top), (button_right, button_bottom), status_color, -1)
            text_size = cv2.getTextSize(status, cv2.FONT_HERSHEY_SIMPLEX, 0.9, 2)[0]
            text_x = max(button_left + 8, (display.shape[1] - text_size[0]) // 2)
            cv2.putText(display, status, (text_x, button_top + 39), cv2.FONT_HERSHEY_SIMPLEX, 0.9, (255, 255, 255), 2, cv2.LINE_AA)

            if scan_started is None:
                next_in = max(0, int(next_scan - now))
                timing = f"Next scan: {next_in}s"
            else:
                timing = f"Scan: {max(0, int(args.scan_seconds - (now - scan_started)))}s  votes={sum(match_votes)}/{len(match_votes)}"
            live_score = f"  live score={score_for_display:.1f}" if score_for_display is not None else ""
            draw_text(display, f"{timing}  threshold={threshold:.1f}{live_score}", panel_top + 100)
            draw_text(display, detail[:88], panel_top + 126, (210, 210, 210))
            draw_text(display, "Space=scan now   +/-=threshold   S=save profile   Esc=quit", panel_top + 147, (170, 170, 170))
            cv2.imshow(WINDOW_NAME, display)

            key = cv2.waitKey(1) & 0xFF
            if key in (27, ord("q"), ord("Q")):
                return 0
            if key == 32 and camera is not None:
                begin_scan(now)
            elif key in (ord("+"), ord("=")):
                threshold = min(150.0, threshold + 2.0)
                detail = f"Threshold changed to {threshold:.1f}; higher is more permissive."
            elif key in (ord("-"), ord("_")):
                threshold = max(30.0, threshold - 2.0)
                detail = f"Threshold changed to {threshold:.1f}; lower is stricter."
            elif key in (ord("s"), ord("S")):
                save_presence_profile(args, threshold)
                detail = f"Profile saved with threshold {threshold:.1f}."
    finally:
        if camera is not None:
            camera.release()
        cv2.destroyAllWindows()


def self_test(_args) -> int:
    recognizer = create_recognizer(70.0)
    base = np.zeros(FACE_SIZE, dtype=np.uint8)
    cv2.circle(base, (100, 100), 60, 180, -1)
    cv2.circle(base, (78, 85), 8, 20, -1)
    cv2.circle(base, (122, 85), 8, 20, -1)
    cv2.ellipse(base, (100, 120), (25, 12), 0, 0, 180, 30, 4)
    samples = [base, cv2.GaussianBlur(base, (3, 3), 0)]
    recognizer.train(samples, np.asarray([1, 1], dtype=np.int32))
    label, confidence = recognizer.predict(base)
    if label != 1 or confidence > 1.0:
        raise FaceGuardError(f"LBPH self-test failed: label={label}, score={confidence}", 23)
    print(json.dumps({"ok": True, "opencv": cv2.__version__, "score": confidence}))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="CA Unlock Guard local face helper")
    subparsers = parser.add_subparsers(dest="command", required=True)

    enroll_parser = subparsers.add_parser("enroll", help="Capture owner samples and train a local model")
    enroll_parser.add_argument("--model", required=True)
    enroll_parser.add_argument("--camera-index", type=int, default=0)
    enroll_parser.add_argument("--samples", type=int, default=36)
    enroll_parser.add_argument("--sample-interval", type=float, default=0.18)
    enroll_parser.add_argument("--timeout", type=float, default=45.0)
    enroll_parser.add_argument("--threshold", type=float, default=70.0)
    enroll_parser.set_defaults(handler=enroll)

    verify_parser = subparsers.add_parser("verify", help="Verify the face currently in front of the camera")
    verify_parser.add_argument("--model", required=True)
    verify_parser.add_argument("--camera-index", type=int, default=0)
    verify_parser.add_argument("--timeout", type=float, default=15.0)
    verify_parser.add_argument("--threshold", type=float, default=70.0)
    verify_parser.add_argument("--required-matches", type=int, default=5)
    verify_parser.add_argument("--window-size", type=int, default=8)
    verify_parser.set_defaults(handler=verify)

    presence_parser = subparsers.add_parser(
        "presence-test",
        help="Run a periodic green/red/amber camera test that never locks Windows",
    )
    presence_parser.add_argument("--model", required=True)
    presence_parser.add_argument("--profile")
    presence_parser.add_argument("--log")
    presence_parser.add_argument("--camera-index", type=int, default=0)
    presence_parser.add_argument("--threshold", type=float, default=70.0)
    presence_parser.add_argument("--interval", type=float, default=30.0)
    presence_parser.add_argument("--scan-seconds", type=float, default=6.0)
    presence_parser.add_argument("--sample-interval", type=float, default=0.16)
    presence_parser.add_argument("--minimum-quality-frames", type=int, default=8)
    presence_parser.add_argument("--required-matches", type=int, default=5)
    presence_parser.add_argument("--owner-ratio", type=float, default=0.60)
    presence_parser.add_argument("--other-ratio", type=float, default=0.20)
    presence_parser.add_argument("--camera-retry-seconds", type=float, default=3.0)
    presence_parser.add_argument(
        "--duration-hours",
        type=float,
        default=0.0,
        help="Exit automatically after this many hours; 0 runs until Esc",
    )
    presence_parser.set_defaults(handler=presence_test)

    self_test_parser = subparsers.add_parser("self-test", help="Test OpenCV and LBPH without opening a camera")
    self_test_parser.set_defaults(handler=self_test)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if hasattr(args, "window_size") and args.required_matches > args.window_size:
        raise FaceGuardError("required-matches cannot exceed window-size.", 22)
    if hasattr(args, "minimum_quality_frames") and args.required_matches > args.minimum_quality_frames:
        raise FaceGuardError("required-matches cannot exceed minimum-quality-frames.", 22)
    if getattr(args, "owner_ratio", 1.0) <= getattr(args, "other_ratio", 0.0):
        raise FaceGuardError("owner-ratio must be greater than other-ratio.", 22)
    return int(args.handler(args))


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except FaceGuardError as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(exc.exit_code)
    except cv2.error as exc:
        print(f"OpenCV error: {exc}", file=sys.stderr)
        raise SystemExit(24)
