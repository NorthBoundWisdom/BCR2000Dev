import os

from bcr_provider import Client

client = Client(
    os.environ["BCR_PROVIDER_URL"],
    os.environ["BCR_PROVIDER_TOKEN"],
    expected_provider_id=os.environ["BCR_PROVIDER_ID"],
)
for batch in client.events("console"):
    if batch["reset"]:
        print("New snapshot/generation; historical inputs are not replayed as actions")
        continue
    for event in batch["events"]:
        payload = event["payload"]
        if event["kind"] == "control.input" and payload.get("accepted"):
            print(event["source"], payload["control"], payload["raw_value"], payload["mapped_value"])
