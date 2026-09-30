# Pump health, released with care

Companion code for the second session on CI/CD with GitHub Actions.

A water utility logs five readings from each of its pumps once a day. A model
scores the latest readings for the chance that the pump fails within seven
days, and a small FastAPI service answers one question over HTTP: should a
crew inspect this pump first.

This repository starts where the first CI/CD session ended. Every pull request
is tested, and every push to `main` that passes its tests is deployed to
Amazon ECS. The session adds the rest: branch protection, a model-quality
gate, a staging environment with an approval before production, rollback,
notifications, and a weekly check of the live model that can start a retrain.

## Layout

```
app/main.py              the service: GET /health, POST /predict
model/                   model.joblib and meta.json, committed so the image can be built at once
train.py                 fits the model on the history, optionally plus recent labelled weeks
pumps.py                 the pumps, simulated: the history and one week of labelled readings at a time
data/holdout.csv         5,000 labelled readings no model is trained on
tests/                   the service's tests, run on every pull request
infra/                   up.sh and down.sh stand up and delete each environment on AWS
.github/workflows/       the pipeline
Dockerfile, .dockerignore, requirements*.txt
```

## Start

Press **Use this template** to make your own copy, clone it, then

```bash
infra/up.sh production
```

Delete everything with `infra/down.sh` when you are done.
