"""launch --tui：curses 三面板 UI（可安装 / 已安装 / 可更新）。

只做渲染与驱动：数据拉取用 skills.installed()/manifest.*，执行直接调
skills.install/install_local/uninstall/uninstall_local/update —— 不绕过 CLI 语义
（dry-run 打印、confirm 二次确认、lock 合并都在被调函数内部）。

自检: cd script && python3 -m launch.tui
"""

from __future__ import annotations

import curses
import sys
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path

if __package__ in (None, ""):  # 允许 python3 script/launch/tui.py 直接跑自检
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import launch.util as util
from launch import manifest, skills
from launch.agents import LOCK_FILE, AgentSpec, resolve_agent
from launch.freshness import check_freshness

MIN_ROWS, MIN_COLS = 24, 60


@dataclass
class Item:
    kind: str    # "ext"（skills.toml 外部，走 npx）| "local"（仓库自有，走 symlink）
    arg: str     # 传给 skills.* 的 name
    label: str
    note: str = ""


@dataclass
class Panel:
    key: str     # available | installed | update
    title: str
    items: list[Item] = field(default_factory=list)
    checked: set[int] = field(default_factory=set)
    cursor: int = 0
    top: int = 0


@dataclass
class State:
    agent: AgentSpec
    panels: list[Panel]
    view: int = 0
    msg: str = "space 勾选 · enter 执行 · tab 切面板 · ? 帮助"
    help: bool = False


_KEYMAP: dict[int, str] = {
    ord("q"): "quit",
    ord("a"): "agent",
    ord("r"): "refresh",
    ord(" "): "toggle",
    9: "switch",   # tab
    10: "exec", 13: "exec", curses.KEY_ENTER: "exec",
    curses.KEY_UP: "up", curses.KEY_DOWN: "down",
    ord("?"): "help",
}


def _handle_key(key: int) -> str | None:
    """键位 → 动作名（纯映射，自检覆盖）。"""
    return _KEYMAP.get(key)


def _sortkey(item: Item) -> tuple:
    """面板内稳定排序。"""
    return (item.label.lower(), item.kind, item.arg)


def _panels(agent: AgentSpec) -> list[Panel]:
    """拉取三面板数据：available（外部+自有，排除已装）/ installed / update（freshness）。"""
    root = util.repo_root()
    sources = manifest.load_skills(root / "configs" / "skills.toml")
    local_names = manifest.local_skill_names(root)
    installed = {s.name: s for s in skills.installed(agent)}

    avail = [Item("ext", s.name, s.name, s.repo) for s in sources if s.name not in installed]
    avail += [Item("local", n, n, "仓库自有") for n in local_names if n not in installed]
    inst_items = [
        Item("local" if s.source == "local" else "ext", s.name, s.name,
             ("symlink" if s.source == "local" else s.source) + (f" · {s.detail}" if s.detail else ""))
        for s in installed.values()
    ]
    # 离线/限流时 freshness 逐项降级为 unknown → update 面板留空，不致命。
    upd = [Item("ext", v.source.name, v.source.name, v.detail)
           for v in check_freshness(sources, agent.skills_dir, LOCK_FILE)
           if v.verdict == "outdated"]

    return [
        Panel("available", "可安装", sorted(avail, key=_sortkey)),
        Panel("installed", "已安装", sorted(inst_items, key=_sortkey)),
        Panel("update", "可更新", sorted(upd, key=_sortkey)),
    ]


@contextmanager
def _paused(stdscr):
    """执行子进程前临时 endwin 让输出落终端，结束后恢复 curses 模式。"""
    try:
        curses.endwin()
    except curses.error:
        pass
    try:
        yield
    finally:
        try:
            curses.reset_prog_mode()
            stdscr.refresh()
        except curses.error:
            pass


def _execute(stdscr, state: State) -> str:
    """执行当前面板的勾选批，返回状态行文字。"""
    panel = state.panels[state.view]
    sel = [it for i, it in enumerate(panel.items) if i in panel.checked]
    if not sel:
        return "未勾选任何项"
    verb = {"available": "安装", "installed": "卸载", "update": "更新"}[panel.key]
    ext = [it.arg for it in sel if it.kind == "ext"]
    loc = [it.arg for it in sel if it.kind == "local"]
    sources = manifest.load_skills(util.repo_root() / "configs" / "skills.toml")
    with _paused(stdscr):
        if not util.confirm(f"确认{verb}勾选的 {len(sel)} 项?"):
            return "已取消"
        rc = 0
        if panel.key == "available":
            if ext:
                rc |= skills.install(sources, state.agent, names=ext)
            if loc:
                rc |= skills.install_local(loc, state.agent)
        elif panel.key == "installed":
            if loc:
                rc |= skills.uninstall_local(loc, state.agent)
            if ext:
                rc |= skills.uninstall(ext, state.agent)
        elif ext:
            rc |= skills.update(ext, state.agent)
    if rc == 0:
        return f"{verb}完成: 成功 {len(sel)} 项"
    return f"{verb}完成: 勾选 {len(sel)} 项, 部分失败 (退出码 {rc})"


def _draw(stdscr, state: State) -> None:
    rows, cols = stdscr.getmaxyx()
    stdscr.erase()
    width = max(0, cols - 1)

    def put(y: int, text: str, attr: int = 0) -> None:
        # 小窗口下逐行钳制，永不越界 crash。
        if 0 <= y < rows and width:
            try:
                stdscr.addstr(y, 0, text[:width], attr)
            except curses.error:
                pass

    status = f" agent={state.agent.key}{'  [DRY-RUN]' if util.DRY_RUN else ''}  {state.msg}"
    if rows < MIN_ROWS or cols < MIN_COLS:
        status += f"  ⚠终端过小 (建议 ≥{MIN_ROWS}x{MIN_COLS})"
    put(0, status, curses.A_REVERSE)
    put(1, " tab:切面板  ↑/↓:移动  space:勾选  enter:执行  a:切agent  r:刷新  q:退出  ?:帮助")

    y0 = 2
    body_rows = max(1, rows - y0 - (len(state.panels) - 1) * 3)
    y = y0
    for idx, panel in enumerate(state.panels):
        active = idx == state.view
        base = y
        put(base, f"{'▶' if active else ' '} [{panel.title}] "
                  f"{len(panel.items)} 项 · 勾选 {len(panel.checked)}",
            curses.A_REVERSE if active else curses.A_DIM)
        if active:
            if panel.top > panel.cursor:
                panel.top = panel.cursor
            if panel.cursor >= panel.top + body_rows:
                panel.top = panel.cursor - body_rows + 1
            if panel.top < 0:
                panel.top = 0
            if not panel.items:
                put(base + 1, "  (空)")
            for off, item in enumerate(panel.items[panel.top:panel.top + body_rows]):
                i = panel.top + off
                mark = ">" if i == panel.cursor else " "
                box = "[x]" if i in panel.checked else "[ ]"
                put(base + 1 + off, f"{mark}{box} {item.label}  {item.note}".rstrip(),
                    curses.A_BOLD if i == panel.cursor else curses.A_NORMAL)
            y = base + 1 + body_rows
        else:
            # 非活动面板固定占 3 行：标题 + 最多 2 行预览。
            for item in panel.items[:2]:
                put(y + 1, f"  [ ] {item.label}", curses.A_DIM)
                y += 1
            y = base + 3

    if state.help:
        for off, line in enumerate([
                "space  勾选/取消当前项",
                "enter  执行当前面板勾选批（confirm 二次确认；dry-run 只打印计划）",
                "tab    切换面板（可安装 → 已安装 → 可更新）",
                "a      切换 agent 目标（claude ↔ agents）",
                "r      刷新面板数据",
                "q      退出",
                "按任意键返回",
        ]):
            put(y0 + off, line, curses.A_BOLD)
    stdscr.refresh()


def _loop(stdscr, state: State) -> int:
    try:
        curses.curs_set(0)
    except curses.error:
        pass
    stdscr.keypad(True)
    while True:
        _draw(stdscr, state)
        key = stdscr.getch()
        if state.help:      # 帮助覆盖层：任意键关闭
            state.help = False
            continue
        act = _handle_key(key)
        if act == "quit":
            return 0
        if act == "agent":
            state.agent = resolve_agent("agents" if state.agent.key == "claude" else "claude")
            state.panels = _panels(state.agent)   # 切 agent 后重拉 installed/available
            state.msg = f"已切换 agent → {state.agent.key}"
        elif act == "refresh":
            state.panels = _panels(state.agent)
            state.msg = "已刷新"
        elif act == "switch":
            state.view = (state.view + 1) % len(state.panels)
        elif act == "help":
            state.help = True
        elif act == "toggle":
            panel = state.panels[state.view]
            if panel.items:
                panel.checked.symmetric_difference_update({panel.cursor})
        elif act in ("up", "down"):
            panel = state.panels[state.view]
            if panel.items:
                panel.cursor = max(0, min(len(panel.items) - 1,
                                          panel.cursor + (-1 if act == "up" else 1)))
        elif act == "exec":
            state.msg = _execute(stdscr, state)
            state.panels = _panels(state.agent)   # 执行后刷新面板


def run(agent_key: str) -> int:
    """launch --tui 入口（cli.py 调用）。正常 0；非 TTY / 初始化失败 → err + 2。"""
    if not sys.stdout.isatty() or not sys.stdin.isatty():
        util.err("--tui 需要交互式终端 (TTY)：当前 stdout/stdin 不是终端")
        return 2
    try:
        agent = resolve_agent(agent_key)
    except SystemExit as exc:
        return int(exc.code or 2)
    try:
        return curses.wrapper(_loop, State(agent=agent, panels=_panels(agent)))
    except curses.error as exc:
        util.err(f"TUI 初始化失败: {exc}")
        return 2


if __name__ == "__main__":
    import io
    import os
    from contextlib import redirect_stdout
    from tempfile import TemporaryDirectory

    with TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        root = tmp_path / "repo"
        (root / "configs").mkdir(parents=True)
        (root / "skills" / "loc").mkdir(parents=True)
        (root / "skills" / "loc" / "SKILL.md").write_text(
            "---\nname: loc\n---\n正文\n", encoding="utf-8")
        (root / "configs" / "skills.toml").write_text(
            '[[sources]]\nname = "ext-a"\nrepo = "owner/a"\nskill = "a"\n', encoding="utf-8")
        os.environ["LAUNCH_REPO_ROOT"] = str(root)
        os.environ["CLAUDE_CONFIG_DIR"] = str(tmp_path / "claude-home")
        os.environ["AGENTS_SKILLS_HOME"] = str(tmp_path / "home" / "skills")
        os.environ["SKILLS_LOCK_FILE"] = str(tmp_path / "home" / "lock.json")
        os.environ["SKILLS_API_BASE"] = "http://127.0.0.1:9"  # 不可达端口：freshness 秒失败
        agent = resolve_agent("agents")

        # --- 数据拉取：available(外部+自有) / installed / update(离线→空) ---
        panels = _panels(agent)
        assert [p.key for p in panels] == ["available", "installed", "update"]
        assert [i.arg for i in panels[0].items] == ["ext-a", "loc"]       # sortkey 稳定序
        assert panels[0].items[0].kind == "ext" and panels[0].items[1].kind == "local"
        assert panels[1].items == [] and panels[2].items == []            # 未装 + API 不可达

        assert skills.install_local(["loc"], agent) == 0
        panels = _panels(agent)
        assert [i.arg for i in panels[0].items] == ["ext-a"]              # 已装项移出 available
        assert [(i.arg, i.kind) for i in panels[1].items] == [("loc", "local")]

        # --- 键位 dispatch 纯函数 ---
        for key, act in ((ord("q"), "quit"), (ord("a"), "agent"), (ord("r"), "refresh"),
                         (9, "switch"), (32, "toggle"), (10, "exec"),
                         (curses.KEY_UP, "up"), (curses.KEY_DOWN, "down"), (ord("?"), "help")):
            assert _handle_key(key) == act, (key, act)
        assert _handle_key(1) is None                                     # 未映射键

        # --- fake stdscr 冒烟：导航/勾选/帮助/切 agent/刷新/退出 ---
        class FakeScr:
            def __init__(self, keys: list[int]):
                self._keys = list(keys)

            def getmaxyx(self):
                return 24, 80

            def keypad(self, on):
                pass

            def erase(self):
                pass

            def addstr(self, y, x, text, attr=0):
                pass

            def refresh(self):
                pass

            def getch(self):
                assert self._keys, "按键序列耗尽仍被要求输入"
                return self._keys.pop(0)

        st = State(agent=agent, panels=_panels(agent))
        assert _loop(FakeScr([curses.KEY_DOWN, curses.KEY_UP, 9, 32,
                              ord("?"), ord("x"), ord("a"), ord("r"), ord("q")]), st) == 0
        assert st.view == 1                                   # tab 切到 installed
        assert st.agent.key == "claude"                       # a 已切目标（沙箱空 claude home）
        assert "loc" in {i.arg for i in st.panels[0].items}   # claude home 空 → loc 回到 available
        assert not st.help                                    # 'x' 关闭帮助覆盖层
        assert st.msg == "已刷新"

        # --- exec 冒烟：dry-run 打印计划、无副作用 ---
        st = State(agent=agent, panels=_panels(agent))
        util.DRY_RUN = True
        buf = io.StringIO()
        with redirect_stdout(buf):
            assert _loop(FakeScr([32, 10, ord("q")]), st) == 0
        util.DRY_RUN = False
        out = buf.getvalue()
        assert "[dry-run]" in out and "npx -y skills@latest add" in out
        assert st.msg.startswith("安装完成")
        assert not Path(os.environ["SKILLS_LOCK_FILE"]).exists()          # dry-run 无副作用

    util.log("launch.tui 自检通过")
