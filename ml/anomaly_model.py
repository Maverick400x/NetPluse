"""
NetPulse — offline anomaly detection on exported network metrics.

The app's built-in detector is a rolling z-score on latency (simple and
explainable). This script trains an Isolation Forest on *all* features in the
CSV the app writes, then compares the two approaches.

Usage
-----
  python ml/anomaly_model.py                       # uses the app's default CSV
  python ml/anomaly_model.py --csv path/to/metrics.csv
  python ml/anomaly_model.py --demo                # synthetic data, no Mac needed

Outputs (in --out, default ./ml-report):
  anomalies.csv   every row with model score and flags
  report.png      time-series plot with anomalies highlighted
  summary.txt     counts, precision/recall vs the app's own flags
"""
from __future__ import annotations

import argparse
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from sklearn.ensemble import IsolationForest
from sklearn.preprocessing import StandardScaler

DEFAULT_CSV = Path.home() / "Library/Application Support/NetPulse/metrics.csv"
FEATURES = ["download_mbps", "upload_mbps", "latency_ms", "jitter_ms", "packet_loss", "rssi_dbm"]


def load(csv: Path) -> pd.DataFrame:
    df = pd.read_csv(csv, parse_dates=["timestamp"])
    df = df.sort_values("timestamp").reset_index(drop=True)
    # Lost pings are blank in the CSV — treat them as a very slow reply.
    df["latency_missing"] = df["latency_ms"].isna().astype(int)
    df["latency_ms"] = df["latency_ms"].fillna(df["latency_ms"].quantile(0.99) * 2 if df["latency_ms"].notna().any() else 1000)
    for column in FEATURES:
        df[column] = df[column].astype(float).fillna(df[column].median() if df[column].notna().any() else 0)
    # Rolling context helps the model spot sudden changes, not just extremes.
    df["latency_delta"] = df["latency_ms"].diff().abs().fillna(0)
    df["latency_roll_mean"] = df["latency_ms"].rolling(12, min_periods=1).mean()
    return df


def synthetic(rows: int = 2000, seed: int = 7) -> pd.DataFrame:
    """Fake but realistic data: diurnal traffic, steady ping, injected incidents."""
    rng = np.random.default_rng(seed)
    t = pd.date_range("2026-10-01", periods=rows, freq="5s")
    phase = np.linspace(0, 4 * np.pi, rows)
    down = np.clip(20 + 15 * np.sin(phase) + rng.gamma(2, 4, rows), 0, None)
    up = np.clip(3 + 2 * np.sin(phase) + rng.gamma(1.5, 1, rows), 0, None)
    latency = rng.normal(22, 3, rows)
    jitter = np.abs(rng.normal(2, 0.8, rows))
    loss = np.zeros(rows)
    rssi = rng.normal(-55, 3, rows).round()
    truth = np.zeros(rows, dtype=int)

    for start in rng.choice(np.arange(100, rows - 50), size=6, replace=False):
        span = slice(start, start + rng.integers(5, 25))
        latency[span] += rng.uniform(80, 300)
        jitter[span] += rng.uniform(20, 60)
        loss[span] = rng.uniform(0.05, 0.4)
        truth[span] = 1
    for start in rng.choice(np.arange(100, rows - 50), size=3, replace=False):
        span = slice(start, start + 20)
        rssi[span] -= 25
        down[span] *= 0.2
        truth[span] = 1

    return pd.DataFrame({
        "timestamp": t, "download_mbps": down, "upload_mbps": up, "latency_ms": latency,
        "jitter_ms": jitter, "packet_loss": loss, "rssi_dbm": rssi,
        "device_count": 8, "anomaly": 0, "ground_truth": truth,
        "connection_type": np.where(np.arange(rows) < rows // 2, "wifi", "hotspotWiFi"),
    })


def zscore_baseline(latency: pd.Series, window: int = 24, threshold: float = 3.0) -> np.ndarray:
    """Same rule the macOS app uses (rolling window, z > 3, 2 ms floor)."""
    mean = latency.shift(1).rolling(window, min_periods=6).mean()
    std = latency.shift(1).rolling(window, min_periods=6).std().clip(lower=2)
    return (((latency - mean) / std) > threshold).fillna(False).astype(int).to_numpy()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--csv", type=Path, default=DEFAULT_CSV)
    parser.add_argument("--demo", action="store_true", help="use synthetic data")
    parser.add_argument("--contamination", type=float, default=0.03, help="expected share of anomalies")
    parser.add_argument("--out", type=Path, default=Path("ml-report"))
    args = parser.parse_args()

    if args.demo:
        raw = synthetic()
        tmp = args.out / "synthetic_metrics.csv"
        args.out.mkdir(parents=True, exist_ok=True)
        raw.to_csv(tmp, index=False)
        df = load(tmp)
    else:
        if not args.csv.exists():
            raise SystemExit(f"No CSV at {args.csv}. Run NetPulse for a while first, or use --demo.")
        df = load(args.csv)

    if len(df) < 50:
        raise SystemExit(f"Only {len(df)} rows — let NetPulse collect a few minutes of data first.")

    features = FEATURES + ["latency_missing", "latency_delta", "latency_roll_mean"]
    X = StandardScaler().fit_transform(df[features])

    model = IsolationForest(n_estimators=300, contamination=args.contamination, random_state=42)
    model.fit(X)
    df["iforest_score"] = -model.score_samples(X)          # higher = more anomalous
    df["iforest_flag"] = (model.predict(X) == -1).astype(int)
    df["zscore_flag"] = zscore_baseline(df["latency_ms"])

    args.out.mkdir(parents=True, exist_ok=True)
    df.to_csv(args.out / "anomalies.csv", index=False)

    lines = [
        f"Rows analysed:            {len(df)}",
        f"Isolation Forest flags:   {df['iforest_flag'].sum()}",
        f"Z-score baseline flags:   {df['zscore_flag'].sum()}",
        f"App-reported anomalies:   {int(df['anomaly'].sum())}",
    ]
    if "connection_type" in df and df["connection_type"].notna().any():
        lines.append("")
        lines.append("Per connection type (median values):")
        grouped = df.groupby("connection_type").agg(
            rows=("latency_ms", "size"),
            download=("download_mbps", "median"),
            latency=("latency_ms", "median"),
            loss=("packet_loss", "mean"),
            anomalies=("iforest_flag", "sum"),
        )
        for kind, row in grouped.iterrows():
            lines.append(f"  {kind:<18} rows={int(row.rows):>6}  down={row.download:7.2f} Mbps  "
                         f"ping={row.latency:6.1f} ms  loss={row.loss:6.2%}  anomalies={int(row.anomalies)}")
        lines.append("")
    reference = "ground_truth" if "ground_truth" in df else None
    if reference:
        for name in ("iforest_flag", "zscore_flag"):
            tp = int(((df[name] == 1) & (df[reference] == 1)).sum())
            fp = int(((df[name] == 1) & (df[reference] == 0)).sum())
            fn = int(((df[name] == 0) & (df[reference] == 1)).sum())
            precision = tp / (tp + fp) if tp + fp else 0
            recall = tp / (tp + fn) if tp + fn else 0
            f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0
            lines.append(f"{name:<22} precision={precision:.2f} recall={recall:.2f} f1={f1:.2f}")
    summary = "\n".join(lines)
    (args.out / "summary.txt").write_text(summary + "\n")
    print(summary)

    fig, axes = plt.subplots(4, 1, figsize=(14, 10), sharex=True)
    plots = [("download_mbps", "Download (Mbps)"), ("latency_ms", "Latency (ms)"),
             ("packet_loss", "Packet loss"), ("rssi_dbm", "Wi-Fi RSSI (dBm)")]
    flagged = df[df["iforest_flag"] == 1]
    for ax, (column, label) in zip(axes, plots):
        ax.plot(df["timestamp"], df[column], linewidth=0.8, color="#3b6fd8")
        ax.scatter(flagged["timestamp"], flagged[column], color="#d8433b", s=10, label="Isolation Forest anomaly", zorder=3)
        ax.set_ylabel(label)
        ax.grid(alpha=0.25)
    axes[0].legend(loc="upper right")
    axes[0].set_title("NetPulse metrics with detected anomalies")
    fig.tight_layout()
    fig.savefig(args.out / "report.png", dpi=130)
    print(f"Report written to {args.out.resolve()}")


if __name__ == "__main__":
    main()
