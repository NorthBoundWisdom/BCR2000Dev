#!/usr/bin/env python3
"""Create F candidate field instructions only; never connects to a device."""

import argparse
import json
from pathlib import Path


def plan():
    probe = "python3 <delivery>/diagnostics/f_candidate_probe.py --sdk <delivery>/surface-control-sdk-1.4.0.zip --url <owned-ready-url> --instance <owned-instance> --mapping-revision 0283a140c7e310a1"
    # Each probe receives its credential from a private anonymous pipe owned by the supervising process.
    rows = [
        (
            "preset",
            False,
            "<delivery>/BCRProfileTool --verify-hardware-candidate <candidate-directory>",
            "请确认设备当前预设编号，并核对已学习CC地址；不切换、不写预设。",
            "当前预设与这份候选的CC8/9、67/68地址和momentary模式一致吗？",
            "原map/config哈希与candidate-manifest匹配、software_ready=true、hardware_qualified=false；人的预设编号/一致回答单独留证，否即停止",
        ),
        (
            "start-observe",
            False,
            "<delivery>/BCRProviderService --source hardware --hardware-profile --hardware-map <candidate-directory>/candidate-hardware-map.json --configuration <candidate-directory>/candidate-configuration.json --surface-instance-id <owned-instance> --port 0 --token-stdin",
            "未来得到本次在场授权后，仅启动隔离observe进程，不发显示。",
            "当前设备/端点是本次验收对象吗？",
            "ready.source=hardware、hardware_output=observe；profile bcr2000.hardware/1.4、mapping=0283a140c7e310a1；启动发送0",
        ),
        (
            "enable-edges",
            False,
            probe + " --action edges --control button.1.1",
            "等awaiting_new_edges后，按下并松开使能候选按钮一次。",
            "这个按钮按下与松开各发生一次吗？",
            "CC67按下127/松开0→同epoch硬件accepted boolean true/false；两个新边沿，其他值或断代失败",
        ),
        (
            "stop-edges",
            False,
            probe + " --action edges --control button.1.2",
            "等awaiting_new_edges后，按下并松开停止候选按钮一次。",
            "这个按钮按下与松开各发生一次吗？",
            "CC68按下127/松开0→同epoch硬件accepted boolean true/false；两个新边沿",
        ),
        (
            "start-display",
            False,
            "<delivery>/BCRProviderService --source hardware --hardware-profile --hardware-output write --allow-surface-feedback --hardware-map <candidate-directory>/candidate-hardware-map.json --configuration <candidate-directory>/candidate-configuration.json --surface-instance-id <owned-instance> --port 0 --token-stdin",
            "先停止observe进程，确认人在场后启动write+显示；启动不发送。",
            "可以，人在现场且允许接下来的逐灯测试吗？",
            "新epoch/inputs未知；write且显示权限；startup sends=0；不得复用旧expected",
        ),
    ]
    expanded = []
    for row in rows:
        expanded.append(row)
        if row[0] in ("enable-edges", "stop-edges"):
            expanded.append(
                (
                    row[0] + "-raw",
                    False,
                    row[2].replace("--action edges", "--action raw-edges"),
                    "等awaiting_new_raw_edges后，再按下并松开同一按钮。",
                    "同一按钮按下/松开各一次了吗？",
                    "Provider1.0 console_events同generation无gap：指定CC67/68 channel0原始127/0；不是仅布尔证据",
                )
            )
    rows = expanded
    for control, cc in [("button.1.1", 67), ("button.1.2", 68)]:
        for value in ("on", "off"):
            rows.append(
                (
                    control + "-" + value,
                    True,
                    probe + f" --action display --control {control} --value {value} --confirm-attended-display",
                    f"仅发送{control}灯{value}，请观察对应灯。",
                    f"对应灯是否确实{value}且其他灯没有变化？",
                    f"只有CC{cc}单条127/0传输accepted；输入序号不变；现场on/off原话独立记录；sent不等于灯亮",
                )
            )
    rows += [
        (
            "chain-plan",
            False,
            "python3 <RobimPipe>/configs/run_teleop_chain.py --unit <owned-unit> --mode hardware --console-host bcr --surface-url <owned-ready-url> --surface-instance-id <owned-instance> --delivery <delivery> --run-directory <fresh-run-directory> --allow-hardware-teleop --plan",
            "先核对Pipe仅自有Mock部署和候选角色配置；本轮只生成计划。",
            "确认目标只有本次自有Mock底盘吗？",
            "owned_mock/hardware-attended；精确manifest+mapping pin；无真实执行器；原默认按钮不可用时不得绕过门禁",
        ),
        (
            "chain-enable",
            True,
            "python3 <RobimPipe>/configs/run_teleop_chain.py --unit <owned-unit> --mode hardware --console-host bcr --surface-url <owned-ready-url> --surface-instance-id <owned-instance> --delivery <delivery> --run-directory <fresh-run-directory> --allow-hardware-teleop",
            "联合验收才移除plan：双轴归中，按住使能后小幅动轴；按现场入口新阶段提示推进。",
            "使能前双轴均已归中吗？",
            "button.1.1活跃+connected+同epoch+双轴居中后才有租约；位移证据来自Mock actual，不是Provider target",
        ),
        (
            "chain-release-stop",
            True,
            "python3 <RobimPipe>/configs/attended_chain.py --run-directory <fresh-run-directory> --phase <current-prompted-phase> --yes",
            "先松开使能验证停止，再重新准备后按停止，最后另次重新准备后拔USB。",
            "每一步Mock实际值都归零并释放租约了吗？",
            "松手、button.1.2、link断开三次独立失效关闭；新epoch旧输入不重放；不自动重新武装",
        ),
    ]
    return {
        "schema_version": 1,
        "scope": "PREPARE_ONLY; physical steps require new attended authorization",
        "hardware_qualified": False,
        "automatic_promotion": False,
        "credential_delivery": "private pipe only; never argv/file/report",
        "steps": [
            dict(
                id="F-B-" + key,
                sends_to_device=sends,
                command=cmd,
                say_before=say,
                ask=ask,
                auto_check=check,
                on_fail="停止、不重试、不安装候选、不继续发送",
            )
            for key, sends, cmd, say, ask, check in rows
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("build/f/attended"))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    value = plan()
    (args.output / "bcr-four-role-candidate.json").write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    lines = ["# F BCR four-role candidate plan", "", value["scope"], ""]
    for row in value["steps"]:
        lines.extend(["## " + row["id"], "", *(f"**{key}**: {value}" for key, value in row.items()), ""])
    (args.output / "bcr-four-role-candidate.md").write_text("\n".join(lines) + "\n")
    print(
        json.dumps(
            {
                "steps": len(value["steps"]),
                "sends_steps": sum(row["sends_to_device"] for row in value["steps"]),
                "hardware_executed": 0,
            }
        )
    )


if __name__ == "__main__":
    main()
