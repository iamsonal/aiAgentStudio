---
title: Hold a conversation
description: Keep one run open across several messages from the same person, for example on a record page.
---

A conversational agent keeps one run open while a person sends several messages. Each reply goes to the same run, so the agent remembers what was said.

## Set it up

1. On the agent, set **Wait for Reply (Hours)** to how long the run waits for the next message, from 1 to 168.
2. Build a screen Flow for the record page:
   1. On the first screen, ask for the person's message.
   2. Start the run with **Start Agent Run**. Pass the message as **Input** and `{!recordId}` as **Anchor Record ID**.
   3. Read the answer with **Get Agent Run Result**. While Status is Running, show a screen with a **Refresh** button that loops back to this step. The answer is ready when Status is Waiting.
   4. Show the answer. Ask for the next message.
   5. Send it with **Reply to Agent Run**, then read the answer again.
3. Add the Flow to the record page in Lightning App Builder.

## Rules

- Only the person who started the run, or an operator, may reply.
- The limits on the agent, such as Max Model Calls, apply to each reply on its own.
- The run ends with its last answer when the wait runs out. Start a new run to continue after that.
- **Transcript Turn Limit** decides how many earlier messages the model sees. Older ones are dropped first.
- Reply to Agent Run works only while the run waits for the person. While the agent is still answering, it returns "This run is not waiting for a person's reply." Read the answer first.

## Cost

Each reply is at least one model call. On an agent with an identity, each reply also costs 2 jobs and 1 API call to sign in as the execution user.
