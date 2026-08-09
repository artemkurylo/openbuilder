"""openbuilder-waker — start the instance when, and only when, GitHub has work.

This is the missing half of the autonomy loop. The instance already powers
itself OFF: `ob-idle-stop` stops it once no lock is held, `ob-poll --dry-run`
reports nothing actionable, and nothing has been written under log/ or state/
for OPENBUILDER_IDLE_STOP_MINUTES. Until now the only thing that powered it back
ON was `ob_ensure_running` in the laptop CLI, so a review labelled from the
GitHub web UI stalled the loop until someone opened a terminal.

An EventBridge rule invokes this every few minutes. It evaluates the same rule
table as `ob-poll` (see waker/github.py) and calls `ec2:StartInstances` only when
the instance is stopped AND at least one slug is actionable. It never stops the
instance: that decision stays with the instance itself, which is the only party
that knows whether a job is mid-flight.

The whole run is one API-Gateway-free, VPC-free, dependency-free function, so a
tick costs microcents and sits inside the perpetual free tier.
"""

import datetime
import json
import os

import boto3
import botocore.exceptions

import github

# Created at import so warm invocations reuse the connection pools.
_ssm = boto3.client("ssm")
_ec2 = boto3.client("ec2")

_PARAMETERS = ("github_app_id", "github_app_installation_id", "github_app_private_key")

# StartInstances failures that are the AZ's fault, not ours, and that the next
# tick may well succeed at. The instance is pinned to one subnet — its EBS root
# volume is AZ-bound, so it cannot be started anywhere else — which makes
# "come back in a few minutes" the only available strategy. Observed for real:
# t4g.medium in eu-central-1a refused a start with InsufficientInstanceCapacity.
_TRANSIENT_START_ERRORS = (
    "InsufficientInstanceCapacity",
    "Unsupported",
    "RequestLimitExceeded",
)


def _config() -> dict:
    prefix = os.environ["OPENBUILDER_SSM_PREFIX"].rstrip("/")
    names = [f"{prefix}/{name}" for name in _PARAMETERS]
    response = _ssm.get_parameters(Names=names, WithDecryption=True)
    if response.get("InvalidParameters"):
        raise RuntimeError(f"missing SSM parameters: {response['InvalidParameters']}")
    values = {p["Name"].rsplit("/", 1)[1]: p["Value"] for p in response["Parameters"]}
    unset = sorted(k for k, v in values.items() if not v or v == "REPLACE_ME")
    if unset:
        raise RuntimeError(f"SSM parameters still unset: {unset}")
    return values


def _repos() -> list[str]:
    return [r.strip() for r in os.environ.get("OPENBUILDER_REPOS", "").split(",") if r.strip()]


def _instance() -> tuple[str, datetime.datetime]:
    instance_id = os.environ["OPENBUILDER_INSTANCE_ID"]
    reservations = _ec2.describe_instances(InstanceIds=[instance_id])["Reservations"]
    instance = reservations[0]["Instances"][0]
    return instance["State"]["Name"], instance["LaunchTime"]


def lambda_handler(event, context):  # noqa: ARG001 — EventBridge passes both
    branch_prefix = os.environ.get("OPENBUILDER_BRANCH_PREFIX", "openbuilder")
    label_prefix = os.environ.get("OPENBUILDER_LABEL_PREFIX", "openbuilder")
    flap_guard = int(os.environ.get("OPENBUILDER_FLAP_GUARD_MINUTES", "20"))
    instance_id = os.environ["OPENBUILDER_INSTANCE_ID"]

    values = _config()
    token = github.installation_token(
        values["github_app_id"],
        values["github_app_installation_id"],
        values["github_app_private_key"],
    )

    verdicts: list[dict] = []
    for repo in _repos():
        verdicts.extend(github.decide(token, repo, branch_prefix, label_prefix))
    for verdict in verdicts:
        # Same shape as ob-poll's decision lines, so the two logs read alike.
        print(
            "DECISION repo={repo} slug={slug} rule={rule} actionable={actionable} "
            "reason={reason}".format(**verdict)
        )

    actionable = [v for v in verdicts if v["actionable"]]
    result = {
        "actionable": len(actionable),
        "slugs": [f"{v['repo']}#{v['slug']}" for v in actionable],
        "started": False,
    }
    if not actionable:
        result["outcome"] = "nothing-to-do"
        print(json.dumps(result))
        return result

    state, launch_time = _instance()
    result["instance_state"] = state
    if state != "stopped":
        # running/pending: the instance is already on and its own poll timer owns
        # the work. stopping: leave it alone and pick it up on the next tick,
        # rather than racing the shutdown.
        result["outcome"] = f"instance-{state}"
        print(json.dumps(result))
        return result

    # Flap guard. ob-idle-stop needs OPENBUILDER_IDLE_STOP_MINUTES (30 by
    # default) of quiet before it stops, so a legitimate cycle can never be
    # shorter than that. A stopped instance that was launched minutes ago means
    # the instance concluded there was nothing to do while we concluded the
    # opposite — starting it again would bill a loop. Refuse, loudly.
    age_minutes = (
        datetime.datetime.now(datetime.timezone.utc) - launch_time
    ).total_seconds() / 60
    if age_minutes < flap_guard:
        result["outcome"] = "flap-guard"
        result["minutes_since_launch"] = round(age_minutes, 1)
        print(
            f"REFUSING to start {instance_id}: it was launched "
            f"{age_minutes:.1f} min ago and is already stopped again, but "
            f"{result['slugs']} still looks actionable. The instance and the "
            "waker disagree — check `ob-poll --dry-run` on the instance instead "
            "of starting it in a loop."
        )
        print(json.dumps(result))
        return result

    try:
        _ec2.start_instances(InstanceIds=[instance_id])
    except botocore.exceptions.ClientError as error:
        code = error.response.get("Error", {}).get("Code", "")
        if code not in _TRANSIENT_START_ERRORS:
            raise
        # Not an error to alarm on: the work stays queued in GitHub, and the
        # next tick tries again. Swallowing it keeps the function's error metric
        # meaningful — reserved for bugs and broken credentials.
        result["outcome"] = "start-refused"
        result["error"] = code
        print(
            f"could not start {instance_id}: {code}. {result['slugs']} stays "
            "queued; retrying on the next tick. Capacity in the instance's "
            "availability zone is the usual cause and it clears on its own."
        )
        print(json.dumps(result))
        return result

    result["started"] = True
    result["outcome"] = "started"
    print(f"started {instance_id} for {result['slugs']}")
    print(json.dumps(result))
    return result
