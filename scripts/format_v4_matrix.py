#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Apply v2 column widths + 3/4/5 phase multipliers to v4 matrix."""
from pathlib import Path

import pandas as pd
from openpyxl import load_workbook
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side

V2 = Path(r"C:\Users\d00804096\Desktop\AI平台功能设计矩阵_v2.xlsx")
V4 = Path(r"C:\Users\d00804096\Desktop\AI平台功能设计矩阵_v4.xlsx")
OUTPUT = V4

PHASE_MULT = {"阶段1": 3, "阶段2": 4, "阶段3": 5}
PHASE_FINISH = {"阶段1": "2026年12月", "阶段2": "2027年6月", "阶段3": "2027年12月"}

# v2 / generate_design_matrix widths
COL_WIDTHS = {
    "A": 12, "B": 14, "C": 14, "D": 22, "E": 56,
    "F": 18, "G": 18, "H": 18, "I": 18, "J": 18,
    "K": 10, "L": 10, "M": 10, "N": 8, "O": 32,
}


def blank_hierarchy(df: pd.DataFrame) -> pd.DataFrame:
    out = df.copy()
    for col, parents in [("L1", []), ("L2", ["L1"]), ("L3", ["L1", "L2"])]:
        prev = None
        for i in out.index:
            key = tuple(str(out.at[i, p]) for p in parents + [col])
            if key == prev:
                out.at[i, col] = ""
            else:
                prev = key
    return out


def merge_cells(ws, df: pd.DataFrame, header_row: int = 1) -> None:
    n = len(df)
    start = header_row + 1
    if n <= 1:
        return

    def merge_col(letter: str, keys: pd.Series) -> None:
        i = 0
        while i < n:
            j = i + 1
            while j < n and keys.iloc[j] == keys.iloc[i]:
                j += 1
            if j - i > 1:
                ws.merge_cells(f"{letter}{start + i}:{letter}{start + j - 1}")
            i = j

    merge_col("A", df["L1"].astype(str))
    merge_col("B", df["L1"].astype(str) + "\0" + df["L2"].astype(str))
    merge_col(
        "C",
        df["L1"].astype(str) + "\0" + df["L2"].astype(str) + "\0" + df["L3"].astype(str),
    )


def apply_styles(ws, header_row: int = 1, width_ref=None) -> None:
    fill = PatternFill("solid", fgColor="B4C7E7")
    font = Font(bold=True)
    center = Alignment(horizontal="center", vertical="center", wrap_text=True)
    left = Alignment(horizontal="left", vertical="top", wrap_text=True)
    thin = Side(style="thin", color="B4B4B4")
    border = Border(left=thin, right=thin, top=thin, bottom=thin)

    headers = {ws.cell(header_row, c).value: c for c in range(1, ws.max_column + 1)}

    for c in range(1, ws.max_column + 1):
        cell = ws.cell(header_row, c)
        cell.fill = fill
        cell.font = font
        cell.alignment = center
        cell.border = border

    desc_col = headers.get("功能描述")
    for r in range(header_row + 1, ws.max_row + 1):
        for c in range(1, ws.max_column + 1):
            cell = ws.cell(r, c)
            cell.border = border
            cell.alignment = left if c == desc_col else center

    widths = width_ref or COL_WIDTHS
    for letter, w in widths.items():
        ws.column_dimensions[letter].width = w
    # extra columns beyond O/P
    for col in range(1, ws.max_column + 1):
        letter = ws.cell(header_row, col).column_letter
        if letter not in widths:
            ws.column_dimensions[letter].width = 13

    # row height for readability
    for r in range(header_row + 1, ws.max_row + 1):
        ws.row_dimensions[r].height = 48


def apply_workload_multipliers(df: pd.DataFrame) -> pd.DataFrame:
    """If not yet multiplied: detect base by dividing; apply 3/4/5 once."""
    out = df.copy()
    # Store base before multiply - assume current values may already be base or multiplied
    # User asked latest = 3/4/5 on base estimates from design
    # Re-derive base: if phase1 total ~114 already, skip; if ~38, multiply
    p1_total = out.loc[out["阶段"] == "阶段1", "总工作量(人月)"].sum()
    already = p1_total > 80  # heuristic

    if already:
        print("Workload appears already multiplied, re-base from /mult then re-apply")
        for ph, m in PHASE_MULT.items():
            mask = out["阶段"] == ph
            out.loc[mask, "开发工作量(人月)"] = (out.loc[mask, "开发工作量(人月)"] / m).round(4)
            out.loc[mask, "测试工作量(人月)"] = (out.loc[mask, "测试工作量(人月)"] / m).round(4)
            out.loc[mask, "总工作量(人月)"] = (out.loc[mask, "总工作量(人月)"] / m).round(4)

    for ph, m in PHASE_MULT.items():
        mask = out["阶段"] == ph
        out.loc[mask, "开发工作量(人月)"] = (out.loc[mask, "开发工作量(人月)"] * m).round(2)
        out.loc[mask, "测试工作量(人月)"] = (out.loc[mask, "测试工作量(人月)"] * m).round(2)
        out.loc[mask, "总工作量(人月)"] = (out.loc[mask, "总工作量(人月)"] * m).round(2)
    return out


def main():
    xl = pd.ExcelFile(V4)
    df = pd.read_excel(V4, sheet_name="功能设计总表")
    other_sheets = {
        n: pd.read_excel(V4, sheet_name=n) for n in xl.sheet_names if n != "功能设计总表"
    }

    for c in ["L1", "L2", "L3"]:
        df[c] = df[c].ffill()

    print("Before multiply:")
    for ph in PHASE_MULT:
        sub = df[df["阶段"] == ph]
        print(f"  {ph}: {len(sub)} items, {sub['总工作量(人月)'].sum():.1f} 人月")

    df = apply_workload_multipliers(df)

    print("After multiply (x3/x4/x5):")
    summary_rows = []
    for ph, m in PHASE_MULT.items():
        sub = df[df["阶段"] == ph]
        total = round(sub["总工作量(人月)"].sum(), 1)
        dev = round(sub["开发工作量(人月)"].sum(), 1)
        test = round(sub["测试工作量(人月)"].sum(), 1)
        print(f"  {ph}: {len(sub)} items, {total} 人月 (x{m})")
        summary_rows.append(
            {
                "阶段": ph,
                "功能点数": len(sub),
                "工作量系数": f"×{m}",
                "开发工作量(人月)": dev,
                "测试工作量(人月)": test,
                "总工作量(人月)": total,
                "预计完成": PHASE_FINISH[ph],
            }
        )
    summary_df = pd.DataFrame(summary_rows)

    width_ref = {}
    if V2.exists():
        wb2 = load_workbook(V2)
        ws2 = wb2["功能设计总表"]
        for col in range(1, ws2.max_column + 1):
            letter = ws2.cell(1, col).column_letter
            w = ws2.column_dimensions[letter].width
            if w:
                width_ref[letter] = w
        print("Using v2 column widths:", width_ref)
    else:
        width_ref = COL_WIDTHS

    full = df.copy()
    display = blank_hierarchy(full)

    with pd.ExcelWriter(OUTPUT, engine="openpyxl") as writer:
        display.to_excel(writer, sheet_name="功能设计总表", index=False)
        ws = writer.sheets["功能设计总表"]
        apply_styles(ws, width_ref=width_ref)
        merge_cells(ws, full)
        summary_df.to_excel(writer, sheet_name="阶段汇总", index=False)
        apply_styles(writer.sheets["阶段汇总"], width_ref=width_ref)
        for name, sdf in other_sheets.items():
            if name != "阶段汇总":
                sdf.to_excel(writer, sheet_name=name, index=False)
                if name in writer.sheets:
                    apply_styles(writer.sheets[name], width_ref=width_ref)

    print(f"\nWritten: {OUTPUT}")
    print(f"Grand total: {df['总工作量(人月)'].sum():.1f} 人月")


if __name__ == "__main__":
    main()
