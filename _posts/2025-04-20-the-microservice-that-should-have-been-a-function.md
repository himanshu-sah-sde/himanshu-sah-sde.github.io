---
layout: post
title: "The Microservice That Should Have Been a Function"
date: 2025-04-20
tags: [engineering, microservices, architecture]
---

I once spent two weeks building a microservice that should have been a 40-line function.

It had its own repo, its own CI pipeline, its own CloudFormation stack, its own on-call rotation. It accepted a payload, did some string manipulation, and returned a result. That's it. Forty lines of logic wrapped in thousands of lines of infrastructure.

I'm not writing this to be self-deprecating. I'm writing this because I see this pattern everywhere, and nobody talks about the real reason it happens: **we reach for the architecture we're comfortable with, not the one the problem needs.**

## The Context

The team was building a distributed PR analysis system — something that could look at code changes across repositories, detect downstream impacts, and suggest fixes. We already had six services handling things like SCM integration, queue management, graph modeling, and result aggregation.

The seventh service seemed like a natural extension. Its job was to parse commit messages and extract metadata — things like ticket references, semantic versioning bumps, and change categories. In isolation, it sounded like a reasonable microservice. It had a clear input, a clear output, and a distinct "responsibility."

So we gave it the full treatment. A new repo. A CDK stack for its Lambda. An SQS queue feeding into it. CloudWatch dashboards. Alarms. A runbook page on the wiki. The works.

## The Moment I Realized The Mistake

About a month after shipping, I was debugging a latency issue in the analysis pipeline. A user's PR was taking 8 seconds to process, which was way outside our SLA. I traced the request through our services, watching it hop from one to the next.

When it hit service number seven — the commit message parser — it added 200ms just from the cold start. The actual parsing took 3ms. The rest was network overhead, serialization, deserialization, and Lambda initialization.

I sat there looking at the trace and thought: if this were a function call inside service six, it would take 3ms total. Not 200ms. Not a network hop. Not a separate deployment. Three milliseconds.

Then I looked at who called this service. One caller. Service six. Always synchronously. Always waiting for the response before proceeding.

Then I looked at the scaling characteristics. It received exactly as many messages as service six sent. No independent scaling needs. No burst patterns that differed from its caller.

Then I looked at its data. It had no database. No state. No storage. It was purely computational.

It was a function. We'd just put it on a server for no reason.

## Why This Happens

I've thought about this a lot since then, and I think there are three forces that push teams toward over-extraction:

**The "single responsibility" misunderstanding.** People read about the Single Responsibility Principle and interpret it as "every distinct operation should be its own service." But SRP is about cohesion within a module, not about network boundaries. A function inside a service can have a single responsibility without being a separate deployment unit.

**Resume-driven architecture.** This one's uncomfortable to admit. But building a new service feels more impressive than writing a utility function. It's a bigger PR, a more interesting architecture diagram, a better story in a design review. We optimize for how our decisions look, not how they perform.

**The sunk cost of tooling.** Once you have a service template that spins up a new repo with CI/CD, monitoring, and infrastructure — it feels effortless to create another service. The marginal cost seems low. But the marginal cost of a new service is never just the setup. It's the ongoing maintenance, the deployment coordination, the cognitive overhead of another moving part in your system.

## The Actual Cost (Measured, Not Theoretical)

After I realized the problem, I spent a week tracking the real cost of this unnecessary service:

**Latency:** 200ms added to every request. At 50k PRs analyzed per month, that's 2.7 hours of cumulative user-facing latency that didn't need to exist.

**Deployment coupling:** We couldn't ship changes to the calling service without first verifying that the parser service was healthy and compatible. This added about 15 minutes to every deployment, twice a week. That's 26 hours per year of engineer time spent waiting.

**Debugging overhead:** When something went wrong in the pipeline, engineers had to check logs across two services instead of one. The context switch between CloudWatch log groups, the correlation of request IDs across service boundaries — it added 10-15 minutes to every investigation.

**On-call burden:** Someone had to understand this service. When it alarmed at 2am (usually because of a Lambda cold start spike that was completely benign), someone had to wake up, look at it, and decide it was fine. We had three false-positive pages in two months.

**Infrastructure cost:** The Lambda, the SQS queue, the CloudWatch dashboards, the alarms — roughly $40/month. Not much individually, but multiply by all the services that shouldn't exist across an organization.

Combined: roughly 3-4 engineer-days per quarter. For string parsing.

## The Fix

I moved the parsing logic into a module within service six. It took half a day. The module is 52 lines of code (slightly more than my original estimate because I added better error handling). It's tested with unit tests in the same repo. It deploys with the service it belongs to.

Latency for that operation went from 200ms to 3ms. Debugging now happens in one log group. Deployments are simpler. On-call no longer gets paged for cold start spikes on a service that doesn't exist.

## The Heuristic I Use Now

Before creating a new service, I ask five questions:

1. **Does it need to scale independently?** Not "could it theoretically need to someday" — does it actually need to today, based on real traffic patterns?

2. **Does it have its own data?** If it doesn't own a data store — if it's purely computational or passes through data — it's probably not a service.

3. **Would a different team ever own this?** If the same three people maintain both the caller and the callee, the service boundary is organizational theater.

4. **Does it have multiple callers?** If only one service ever calls it, you don't have a service — you have a remote function call with extra steps.

5. **Does it need independent deployability?** If it always changes in lockstep with its caller, separate deployments are overhead, not flexibility.

If you can't answer "yes" to at least two of these, it should probably be a module, a library, or just a function in an existing service.

## The Broader Pattern

This isn't just about microservices. It's about a tendency in software engineering to introduce abstraction before we have evidence that the abstraction is needed.

I see it with libraries extracted too early ("we might reuse this!"). With databases split prematurely ("this table might need to scale differently!"). With event buses introduced for communication between two components that could just call each other.

Every architectural boundary has a cost. Network boundaries have latency, serialization overhead, and failure modes. Module boundaries have indirection and cognitive overhead. Even function boundaries have stack frame cost and naming burden.

The question isn't whether a boundary is "clean." It's whether the cost of the boundary is justified by a real, current need.

## What I Tell Junior Engineers

When someone on my team proposes a new service, I don't say no. I ask: "What would it look like if this were a module inside the existing service?" Usually, it looks simpler. Sometimes the conversation reveals that yes, there's a genuine reason for the boundary — different scaling needs, different ownership, independent data. Great. Build the service.

But often, the honest answer is: "It would be a function. And that would be fine."

The best architecture isn't the one with the most boxes on the diagram. It's the one where every box earns its place.
