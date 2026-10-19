"""Import Tuner's four model files without modifying the source directory."""
import os
import pathlib
import shutil
import tempfile
import uuid

FILES = tuple(f"lm_{suffix}.marisa" for suffix in ("c_abc", "r_xbx", "u_abx", "u_xbc"))


def data_path():
    return pathlib.Path(os.environ.get("AZOOKEY_DATA_DIR") or
                        str(pathlib.Path(os.environ.get("XDG_DATA_HOME", pathlib.Path.home() / ".local/share")) / "azookey-tree"))


def import_model(source, destination=None):
    source = pathlib.Path(source)
    for name in FILES:
        path = source / name
        if not path.is_file() or not 16 < path.stat().st_size <= 256 * 1024 * 1024:
            raise ValueError(f"個人化モデルの {name} がありません、またはサイズが不正です。")
        with path.open("rb") as stream:
            if stream.read(16) != b"We love Marisa.\0":
                raise ValueError(f"{name} はMARISA形式ではありません。")
    root = pathlib.Path(destination) if destination else data_path() / "personalization"
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    # A versioned directory plus one atomic pointer keeps all four files from
    # the same import, including while another input context is using the old one.
    stage = pathlib.Path(tempfile.mkdtemp(prefix="model-", dir=root))
    link = root / f".current-{uuid.uuid4().hex}"
    try:
        for name in FILES:
            shutil.copyfile(source / name, stage / name)
            (stage / name).chmod(0o600)
        link.symlink_to(stage.name, target_is_directory=True)
        link.replace(root / "current")
        return stage
    except Exception:
        link.unlink(missing_ok=True)
        shutil.rmtree(stage)
        raise
