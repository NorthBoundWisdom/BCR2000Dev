#!/usr/bin/env python3
"""Prepare the E attended checklist; generation never opens hardware."""

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "build/e"
# The tracked field tool every step runs; the plan is refused when it is missing.
FIELD = ROOT / "tools/e_attended_field.py"
FIELD_COMMAND = "python3 tools/e_attended_field.py"


def main():
    if not FIELD.is_file():
        raise SystemExit(f"Field tool missing: {FIELD.relative_to(ROOT)}; the plan would not be executable")
    details = [
        (
            "A1",
            True,
            "start-write",
            "我将以write启动隔离Provider。请手离开设备。",
            None,
            "ready.hardware_output=write；记录启动发送数",
        ),
        (
            "A2",
            False,
            "begin-input physical",
            "请先按“编码器组1”键，再转最上面一排最左边旋钮；完成说好了。",
            "操作组1第1钮",
            "hardware输入序号连续；pushEncoder.1.1的已学习映射地址；上下限0..127、步进1",
        ),
        (
            "A3",
            True,
            "five",
            "我将写五个参数值；请观察灯环。",
            "灯环是否跟随并稳定？",
            "sent每次1；无人操作时accepted_hardware_input=0",
        ),
        (
            "A4",
            True,
            "begin-reconnect physical",
            "请拔USB，等3秒，插回；write恢复会回写灯。",
            "拔插USB",
            "代次变化；旧游标拒绝；不重放；记录重连回写",
        ),
        (
            "A5",
            True,
            "switch-map",
            "我将停止后在隔离映射副本切换一个未使用控件，再重启；不改原映射。",
            None,
            "停止旧进程；仅编辑隔离副本；新上下文拒绝旧身份",
        ),
        (
            "A6",
            False,
            "start-observe",
            "我将用缺省observe重启并写软件值；请观察灯环不跟随。",
            None,
            "零发送；console_events含feedback.suppressed",
        ),
        (
            "B1",
            False,
            "start-observe --surface",
            "我将启动1.4只观察实体档案，显示关闭。",
            None,
            "link connected；inputs未知；本方发送0",
        ),
        (
            "B2",
            False,
            "begin-input surface",
            "请转组1第1钮并按一个按键；现有映射按键仅观察，不能使能。",
            "转旋钮、按键",
            "source/origin=hardware；旋钮accepted；现有按键ignored",
        ),
        (
            "B3",
            False,
            "begin-reconnect surface",
            "请拔USB等3秒后插回。",
            "拔插USB",
            "旧epoch stale_epoch；新代次输入未知；不重放",
        ),
        (
            "B4",
            True,
            "start-write --surface",
            "我将开启双显示权限，设置灯环；当前映射按键灯不可写。",
            "亮的是哪个灯环？",
            "write+permission灯环1发送；缺一permission_denied且0发送；按键灯unsupported_feedback",
        ),
    ]
    steps = []
    for identifier, sends, command, say, action, check in details:
        steps.append(
            dict(
                id="E-B" + identifier,
                sends_to_device=sends,
                moves_motors="none",
                command=f"{FIELD_COMMAND} {command}",
                say_before=say,
                confirm_before="可以，人在现场、手已离开设备" if sends else None,
                user_action=action,
                ask=action if action and "？" in action else None,
                expected_answer="记录原话",
                auto_check=check,
                on_fail="停止后续发送并stop；记录原始结果，不重试",
            )
        )
    steps.insert(
        0,
        dict(
            id="E-B00",
            sends_to_device=False,
            moves_motors="none",
            command=f"{FIELD_COMMAND} prepare-map",
            say_before="先复制学习映射到隔离目录；只读原文件，不打开MIDI。",
            confirm_before=None,
            user_action=None,
            ask=None,
            expected_answer=None,
            auto_check="copy=build/e/bcr/hardware-map.json；original_user_mapping_modified=false；已有副本不覆盖",
            on_fail="原映射不存在或无效：停止，不生成替代映射",
        ),
    )
    steps.insert(
        1,
        dict(
            id="E-B0",
            sends_to_device=False,
            moves_motors="none",
            command=f"{FIELD_COMMAND} role-readiness",
            say_before="先只读检查四角色；不打开MIDI，不改学习映射。",
            confirm_before=None,
            user_action=None,
            ask=None,
            expected_answer=None,
            auto_check="机器报告ready=false；enable/stop因visualizationOnly不可用，linear/steer可用；hardware_qualified=false",
            on_fail="exit3为明确未就绪：禁止准备四角色消费者，保留只读观察/替身演练；无自动修映射",
        ),
    )
    value = {
        "schema_version": 1,
        "repository": str(ROOT),
        "scope": "attended plan only; not hardware qualification",
        "sections": ["A Provider 1.0", "B hardware contract 1.4"],
        "mapping": {"copy": str(BASE / "bcr/hardware-map.json"), "original_modified": False},
        "limitations": [
            "当前52按键visualizationOnly：事件ignored、无按键灯反馈；不修改原映射。",
            "A5仅切换隔离副本：备份并移除末尾备用控件、停止后重启，记录新旧代次；不改原映射。",
            "start之间先stop；begin之后用户完成动作才执行end-input或end-reconnect；B断线后surface-rediscover。",
        ],
        "steps": steps,
    }
    BASE.mkdir(exist_ok=True, parents=True)
    (BASE / "bcr-attended.json").write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    lines = ["# E BCR attended plan (not executed on hardware)", "", *value["limitations"], ""]
    for step in steps:
        lines += ["## " + step["id"], "", *("**" + key + "**: " + str(item) for key, item in step.items()), ""]
    (BASE / "bcr-attended.md").write_text("\n".join(lines) + "\n")
    print(json.dumps({"steps": len(steps), "sends_steps": sum(s["sends_to_device"] for s in steps), "motor_steps": 0}))


if __name__ == "__main__":
    main()
