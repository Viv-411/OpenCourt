from opencourt.trackfile import TrackFileHeader, read, write_frame, write_header
from opencourt.types import Track


def test_round_trip(tmp_path):
    path = tmp_path / "clip.tracks.jsonl"
    with open(path, "w") as f:
        write_header(f, TrackFileHeader("clip.mov", 29.97, (1920, 1080), "yolo11n.pt", 1280, 3))
        write_frame(f, 0.1, (Track((1, 2, 3, 4), 7, 0.9), Track((5, 6, 7, 8), None, 0.5)))
        write_frame(f, 0.2, ())
    header, frames = read(path)
    assert header.size == (1920, 1080) and header.step == 3
    obs = list(frames)
    assert [o.t for o in obs] == [0.1, 0.2]
    assert obs[0].tracks[0].track_id == 7 and obs[0].tracks[1].track_id is None
    assert obs[0].tracks[0].foot == (2.0, 4)


def test_track_file_holds_boxes_only(tmp_path):
    """Privacy: the cache is numbers, never pixels."""
    path = tmp_path / "x.jsonl"
    with open(path, "w") as f:
        write_header(f, TrackFileHeader("x", 30, (10, 10), "m", 640, 1))
        write_frame(f, 0.0, (Track((1, 2, 3, 4), 1, 0.5),))
    assert path.stat().st_size < 300
