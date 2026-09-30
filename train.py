"""Train the pump failure model and write it to a folder.

    python train.py                  # history only, writes model/
    python train.py --weeks 36 39    # history plus the labelled weeks 36 to 39
    python train.py --out /out       # writes somewhere else, e.g. a mounted volume

The history is 20,000 readings from the old stations, generated from a fixed seed
in pumps.py. Recent weeks come from pumps.py too. 70% of each recent week goes
into training and 30% is kept back, so the new model can be scored on rows it
never saw (see recent_split and evaluate.py).
"""
import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

import joblib
import numpy as np
import sklearn
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.metrics import roc_auc_score
from sklearn.model_selection import train_test_split

import pumps

# Inspecting a healthy pump costs a crew visit. Missing a failing one costs a
# burst main. So the service flags a pump well below a 50% chance.
THRESHOLD = 0.3
SEED = 7


def recent_split(first: int, last: int):
    """The labelled weeks first..last, split 70/30 within each station."""
    rows = [r for w in range(first, last + 1) for r in pumps.week(w)]
    X, y, stations = pumps.split(rows)
    return train_test_split(X, y, stations, test_size=0.3, stratify=[f"{s}{f}" for s, f in zip(stations, y)],
                            random_state=SEED)


def main(out: Path, weeks) -> None:
    X, y = pumps.make_readings()
    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.25, stratify=y, random_state=SEED
    )
    if weeks:
        X_new, _, y_new, _, _, _ = recent_split(*weeks)
        X_train = np.vstack([X_train, X_new])
        y_train = np.concatenate([y_train, y_new])
    model = HistGradientBoostingClassifier(max_iter=200, learning_rate=0.05, random_state=SEED)
    model.fit(X_train, y_train)
    auc = roc_auc_score(y_test, model.predict_proba(X_test)[:, 1])

    out.mkdir(parents=True, exist_ok=True)
    joblib.dump(model, out / "model.joblib")
    meta = {
        "model_version": datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S"),
        "sklearn_version": sklearn.__version__,
        "features": pumps.FEATURES,
        "threshold": THRESHOLD,
        "test_roc_auc": round(float(auc), 4),
        "failure_rate": round(float(y_train.mean()), 4),
        "trained_on_weeks": list(weeks) if weeks else None,
    }
    (out / "meta.json").write_text(json.dumps(meta, indent=2) + "\n")
    print(f"trained on {len(y_train)} readings, failure rate {y_train.mean():.1%}")
    print(f"test ROC AUC {auc:.4f}, wrote {out}/model.joblib and {out}/meta.json")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, default=Path("model"))
    parser.add_argument("--weeks", type=int, nargs=2, metavar=("FIRST", "LAST"))
    args = parser.parse_args()
    main(args.out, args.weeks)
