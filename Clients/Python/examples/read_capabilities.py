"""Run against a published provider and SDK, with no source checkout required."""

import json
import os

from bcr_provider import Client

client = Client(
    os.environ["BCR_PROVIDER_URL"],
    os.environ["BCR_PROVIDER_TOKEN"],
    expected_provider_id=os.environ["BCR_PROVIDER_ID"],
)
print(json.dumps(client.call("provider_capabilities"), indent=2))
