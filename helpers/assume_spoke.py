import os
import time
import boto3
from dotenv import load_dotenv

load_dotenv()

HUB_PROFILE = os.getenv("HUB_PROFILE", "hub-me")
HUB_ACCOUNT_ID = os.getenv("HUB_ACCOUNT_ID")
SPOKE_ACCOUNT_ID = os.getenv("SPOKE_ACCOUNT_ID")
SPOKE_ROLE_NAME = os.getenv("SPOKE_ROLE_NAME", "SpokeECSRole")
REGION = os.getenv("REGION", "us-west-2")


def assume_spoke_session() -> boto3.Session:
    """
    Assume SpokeECSRole from hub account.

    Returns:
        boto3.Session: Session with spoke account credentials

    Raises:
        RuntimeError: If the assumed role is not in the correct account
    """
    base_session = boto3.Session(profile_name=HUB_PROFILE, region_name=REGION)
    sts = base_session.client("sts")

    spoke_role_arn = f"arn:aws:iam::{SPOKE_ACCOUNT_ID}:role/{SPOKE_ROLE_NAME}"
    resp = sts.assume_role(
        RoleArn=spoke_role_arn,
        RoleSessionName=f"hub-ecs-{int(time.time())}",
    )
    creds = resp["Credentials"]

    spoke_session = boto3.Session(
        aws_access_key_id=creds["AccessKeyId"],
        aws_secret_access_key=creds["SecretAccessKey"],
        aws_session_token=creds["SessionToken"],
        region_name=REGION,
    )

    # Verify identity
    spoke_ident = spoke_session.client("sts").get_caller_identity()
    if spoke_ident["Account"] != SPOKE_ACCOUNT_ID:
        raise RuntimeError(
            f"Expected account {SPOKE_ACCOUNT_ID}, got {spoke_ident['Account']}"
        )

    return spoke_session
