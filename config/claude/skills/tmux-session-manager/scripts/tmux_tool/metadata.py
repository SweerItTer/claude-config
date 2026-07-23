from __future__ import annotations

from .inventory import option_name
from .tmux import TmuxClient


class MetadataWriter:
    def __init__(self, tmux: TmuxClient) -> None:
        self.tmux = tmux

    def tag_managed(
        self,
        scope: str,
        target: str,
        *,
        role: str | None = None,
        note: str | None = None,
        kind: str | None = None,
        peer: str | None = None,
        seed: bool | None = None,
    ) -> None:
        self.tmux.set_user_option(scope, target, option_name(scope, "owner"), target)
        self.tmux.set_user_option(scope, target, option_name(scope, "managed"), "1")
        for suffix, value in (("role", role), ("note", note), ("kind", kind), ("peer", peer)):
            if value is not None:
                self.tmux.set_user_option(scope, target, option_name(scope, suffix), value)
        if seed is not None:
            self.tmux.set_user_option(scope, target, option_name(scope, "seed"), "1" if seed else "0")
