---
layout: post
title: "When Your AI Agent Needs a Software Engineer"
date: 2025-05-10
tags: [ai, engineering, agents]
---

There's a strange moment in building AI agents where you realize the AI isn't the bottleneck anymore. The model is smart enough. The prompts are good enough. The thing that's broken is the software around it.

I've spent the past year building multi-agent systems, and the lesson I keep relearning is this: **AI agents don't fail because the AI is bad. They fail because the engineering is bad.**

This post is about the specific engineering failures I've encountered, what they looked like in production, and what I did about them.

## Agents Are Distributed Systems (But We Pretend They're Not)

Let me describe a system: multiple independent processes communicating through messages, making decisions asynchronously, acting on shared state, with no central coordinator guaranteeing consistency.

That's a distributed system. We've been building those for decades. We have entire textbooks about their failure modes. We have patterns for handling partial failures, eventual consistency, exactly-once delivery, and split-brain scenarios.

Now slap "AI" on it and suddenly we forget all of that.

The first version of our multi-agent system had multiple agents coordinating to analyze code changes. One agent would parse the PR, another would model the codebase graph, another would identify impacts, another would generate recommendations. They communicated through SQS queues and shared state in DynamoDB.

It worked beautifully in demos. In production, it failed in ways that were immediately recognizable to anyone who's built distributed systems — but which caught our AI-focused team completely off guard.

### Failure Mode 1: The Infinite Retry Loop

One of our agents called an external API to fetch repository metadata. When the API returned a 500, the agent's error handling was... optimistic. It would retry. But because the LLM was generating the retry logic, it would sometimes decide to "try a different approach" — which meant calling the same API with slightly different parameters. Still 500. Try again. Different parameters. 500.

The agent entered a loop where it kept calling a failing API with creative variations, burning through our rate limit and generating a $200 OpenAI bill in 40 minutes. There was no circuit breaker. No maximum retry count. No backoff. The model was smart enough to try different approaches, but not smart enough to recognize that the underlying service was down and no variation would help.

**The fix:** We implemented circuit breakers at the tool level. After three consecutive failures to the same endpoint, the tool becomes unavailable to the agent for a cooldown period. The agent gets a clear message: "This service is temporarily unavailable. Report this limitation to the user." The model handles this gracefully — it tells the user what it can't do and what it was able to accomplish without that tool.

### Failure Mode 2: The Silent Data Corruption

Two agents were writing to the same DynamoDB table — one updating analysis results, another updating metadata. There was no coordination between them. Most of the time, they operated on different records and everything was fine.

But occasionally, both agents would update the same record within milliseconds of each other. DynamoDB's last-writer-wins semantics meant one agent's update would silently overwrite the other's. We didn't notice for weeks because the system continued to "work" — it just produced subtly wrong results for about 3% of analyses.

We only caught it when a user complained that their PR analysis showed zero impacted files for a change that obviously affected multiple downstream services. We traced it back to a metadata update that overwrote the impact results.

**The fix:** Optimistic locking with version numbers. Each agent reads the current version, does its work, and writes with a condition check. If the version changed, it re-reads and retries. This is distributed systems 101. We just forgot to apply it because we were thinking about "agents" rather than "concurrent writers."

### Failure Mode 3: The Poison Message

One malformed PR — a merge commit with 4,000 changed files — entered our queue and caused the analysis agent to time out repeatedly. The message would go back to the queue, get picked up again, time out again, go back to the queue. Over and over. Meanwhile, every other PR in the queue was stuck behind it.

This is a classic poison message problem. The fix is a dead-letter queue — after N failed processing attempts, move the message aside for manual investigation. But we didn't have one. We were thinking about "agent capabilities" and "prompt optimization" rather than queue processing fundamentals.

**The fix:** Dead-letter queue with a threshold of 3 attempts. A monitoring alert fires when messages land in the DLQ. A human reviews them, and we use the patterns to improve our input validation so future similar messages are rejected early.

## The MCP Gateway: Where Engineering Complexity Lives

We built an MCP (Model Context Protocol) gateway to let agents access tools — REST APIs, databases, Lambda functions. The idea is elegant: define tools with schemas, let the model decide which to call, execute the calls, return results to the model.

The AI part of this is almost trivial. The model reads tool descriptions, selects the appropriate one, formats parameters according to the schema, and interprets the result. Modern models do this remarkably well.

The engineering part is where all the complexity hides.

### Multi-Tenancy and Isolation

Different teams use our platform with different tools and different access levels. Team A has access to their production database. Team B should never be able to query Team A's database, even accidentally.

This means every tool invocation needs to pass through an authorization layer. The agent's tool calls carry a tenant context. The gateway verifies that the tenant has permission to use that specific tool with those specific parameters. Parameters themselves are validated — you can't pass a database connection string for a database you don't own.

We implemented this with token-based isolation. Each tenant gets a scoped token that encodes their permissions. The gateway validates the token, resolves the tenant's tool registry, and only exposes tools they're authorized to use. The model never even sees tools it can't call.

This sounds straightforward, but the edge cases are endless. What about tools that aggregate data across tenants? What about shared tools with tenant-specific rate limits? What about a tool that writes to a shared resource — how do you audit which tenant caused which write?

### Rate Limiting and Resource Protection

An agent in a reasoning loop can make a lot of tool calls very quickly. We had an agent that decided the best way to find a piece of information was to query every table in a database sequentially. It made 340 API calls in 90 seconds before we noticed.

Each tool now has configurable rate limits per tenant, per agent session, and globally. When a rate limit is hit, the agent gets a clear error: "Rate limit exceeded for this tool. You have made N calls in the last minute. Wait before retrying or try a different approach."

We also implemented cost tracking. Each tool call has an estimated cost (in compute time, API calls, or literal dollars). An agent session has a budget. When it's approaching the budget, it gets a warning. When it exceeds the budget, tool calls are blocked. This prevents runaway sessions from generating unexpected bills.

### Schema Validation and Error Handling

The model generates tool call parameters. Most of the time, they're valid. Sometimes they're not. Maybe it generates a date in the wrong format. Maybe it omits a required field. Maybe it passes a string where a number is expected.

If you pass these malformed requests to downstream services, you get unpredictable behavior. Maybe a 400 error. Maybe a silent failure. Maybe corrupted data.

We validate every tool call against its schema before execution. Invalid calls get rejected with a clear error message that explains what was wrong. The model usually fixes the issue on the next attempt. This validation layer catches about 4% of tool calls — not a lot, but enough that removing it would introduce regular failures.

### Audit Trails

When an agent takes an action in production — modifies a record, sends a notification, creates a resource — someone needs to be able to understand what happened and why.

Every tool invocation is logged with: the tenant, the agent session, the model's reasoning (why it chose this tool), the parameters, the response, and the outcome. This creates an audit trail that lets us answer questions like: "Why did the system send this notification?" or "Who (which agent, which tenant, which user request) caused this database write?"

This audit trail has saved us multiple times. When a user reports an incorrect action, we can trace back through the agent's decision history and identify exactly where it went wrong — was it a retrieval failure? A reasoning error? A tool that returned unexpected data?

## Observability: The Biggest Gap

Traditional software has mature observability tooling. You have metrics, logs, traces. You can see request latency, error rates, throughput. You can trace a request from the load balancer through your services and back.

AI agent systems need all of that, plus a new dimension: **decision observability.** You need to understand not just what the system did, but why it made each decision.

### What We Built

Our observability stack tracks:

**Decision traces:** For each user request, we record the full chain of agent decisions. Which tools did it consider? Which did it choose and why? What did it do with the results? Where did it change direction?

**Confidence signals:** The model often expresses uncertainty in its reasoning. We extract these signals and surface them. If an agent says "I'm not sure if this is the right approach, but..." that's a signal that the result might need human review.

**Retrieval diagnostics:** When the agent retrieves information (from our RAG system or from tool calls), we log what it retrieved, what it used, and what it discarded. This helps us understand when failures are caused by bad retrieval vs. bad reasoning.

**Cost attribution:** Every model call, every tool invocation, every token generated — all attributed to the originating user request. This lets us identify expensive queries, inefficient agent behaviors, and opportunities for optimization.

**Anomaly detection:** We baseline normal agent behavior (typical number of tool calls per request, typical reasoning depth, typical token usage) and alert when sessions deviate significantly. An agent making 50 tool calls for a simple query is probably stuck in a loop.

### The Dashboard That Matters Most

We have a lot of dashboards. The one I check most often shows agent "success paths" — the sequence of decisions that led to a correct outcome — versus "failure paths." Over time, we can see patterns. Most failures share a common decision point where the agent takes a wrong turn. This tells us exactly where to invest in better tooling, better prompts, or better guardrails.

## The Prompt Is Not The Product

I see teams spend weeks perfecting prompts while their error handling is a bare `try/except: pass`. The prompt gets the agent to 80% correctness. The engineering gets it from 80% to production-ready. That last 20% is where trust is built or broken.

What does production-ready engineering for agents look like?

**Graceful degradation.** When the model hallucinates a tool that doesn't exist, don't crash. When it generates malformed output, don't crash. When a downstream service is unavailable, don't crash. Have fallback behaviors. Surface limitations clearly to the user rather than failing silently.

**Structured outputs with validation.** Don't trust the model to return valid JSON every time. Parse it, validate it against a schema, handle the cases where it doesn't comply. Have retry logic specifically for format errors — the model will usually fix its formatting on the second attempt if you tell it what was wrong.

**Circuit breakers at every boundary.** Between agents and tools. Between agents and other agents. Between the system and external services. Every point where a failure could cascade needs a circuit breaker that limits the blast radius.

**Human-in-the-loop escape hatches.** Every autonomous action should have a path back to a human when confidence is low. This isn't a failure of the AI — it's a feature of the system. The best agent systems know when they don't know, and ask for help rather than guessing.

**Timeout budgets.** An agent session should have a maximum duration. A tool call should have a maximum response time. A reasoning chain should have a maximum depth. Without these constraints, edge cases will produce sessions that run for minutes, consuming resources and confusing users.

## The Testing Problem

How do you test a system where the core decision-maker is non-deterministic?

We don't unit test model outputs — that's futile. Instead, we test at three levels:

**Tool-level tests:** Each tool works correctly given valid inputs and handles invalid inputs gracefully. These are regular unit and integration tests.

**Scenario tests:** Given a specific context and user request, does the agent produce an acceptable outcome? We define "acceptable" broadly — there might be multiple valid approaches, and we test that the agent picks any of them. We run these with temperature set to 0 for reproducibility.

**Chaos tests:** We inject failures into tools, inject malformed data into retrieval, inject latency into model calls, and verify that the system degrades gracefully rather than catastrophically. These caught our infinite retry loop and our poison message problem before they hit production (well, before they hit production *again*).

## Where This Is All Going

The teams that will win with AI agents aren't the ones with the best prompts or the most sophisticated reasoning chains. They're the ones that treat agents as software systems — with proper testing, observability, failure handling, and operational runbooks.

The model is a component. An incredibly powerful component that can reason, plan, and make decisions in ways that no traditional software can. But it's a component nonetheless, and it needs the same engineering rigor around it that we'd give any critical dependency. Actually, it needs more rigor, because its behavior is less predictable than a traditional dependency.

If you're building AI agents and you don't have someone thinking about failure modes, retry logic, rate limiting, observability, and operational visibility — you don't have a production system. You have a demo with a deployment pipeline.

The AI makes it smart. The engineering makes it reliable. You need both.
