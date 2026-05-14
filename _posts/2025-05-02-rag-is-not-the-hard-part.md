---
layout: post
title: "RAG Is Not the Hard Part"
date: 2025-05-02
tags: [ai, rag, engineering]
---

Everyone building AI products right now is talking about RAG — Retrieval Augmented Generation. The pitch is simple: chunk your documents, embed them, store them in a vector database, retrieve the relevant ones at query time, and feed them to an LLM. Suddenly your model "knows" your private data.

I've built a RAG system that works over 100k+ documents in production. The retrieval pipeline — the part everyone blogs about — took about two weeks to get working. The other six months were spent on everything else.

The retrieval pipeline is not the hard part. I want to talk about what is.

## Chunking Is a Knowledge Modeling Problem

Every RAG tutorial starts with chunking. "Split your documents into 512 tokens with 50-token overlap." This advice works for a demo with ten blog posts. It breaks down immediately on real documents.

Here's what real documents look like:

**Financial compliance documents** have sections that reference other sections. Section 4.2 says "subject to the constraints in Section 3.1." If your chunk contains 4.2 but not 3.1, the model gives incomplete answers. If you chunk them separately, the retriever might find 4.2 but not 3.1, because the user's query matches the language in 4.2.

**Codebases** have files that only make sense alongside their imports. A utility function means nothing without the context of where it's called. A configuration file means nothing without knowing what it configures.

**Internal wikis** have pages that contradict each other because someone wrote a new process document but forgot to archive the old one. Both get chunked. Both get embedded. Both get retrieved. The model confidently synthesizes contradictory information into a coherent-sounding but wrong answer.

**Long technical documents** have hierarchical structure. A chapter has sections, sections have subsections. A chunk from a subsection might perfectly match the query embedding, but without the parent section's context, it's meaningless or misleading.

### What Actually Worked For Us

We stopped treating documents as flat text. Instead, we model them as graphs.

Each chunk has metadata: what document it belongs to, what section, what subsection, when it was last updated, what other chunks it references. Chunks can be parents of other chunks (a section summary is a parent of its detail paragraphs). Chunks can be newer versions of older chunks.

When the retriever finds a relevant chunk, it doesn't just return that chunk. It walks the graph. It pulls in the parent context. It checks if there's a newer version. It includes referenced sections if they score above a threshold.

This sounds complex, and it is. But it's the difference between a system that works 70% of the time and one that works 92% of the time. That gap matters enormously in production, because users remember the failures, not the successes.

### The Embedding Model Trap

Teams spend weeks evaluating embedding models. "Should we use OpenAI's ada-002? Cohere's embed-v3? A fine-tuned model?" This matters, but less than you think.

The embedding model determines how well your system understands semantic similarity. But most RAG failures aren't semantic similarity failures. They're context failures — the right chunk was retrieved, but it didn't contain enough context to generate a correct answer. Or the wrong chunk was retrieved because the query was ambiguous, and better embeddings wouldn't have helped.

I've seen teams switch embedding models three times, seeing marginal improvements each time, while their chunking strategy — which determines 80% of retrieval quality — remains unchanged from the tutorial they followed on day one.

## Evaluation Is Where Projects Live or Die

Here's the lifecycle of most AI projects I've observed:

1. Build the RAG pipeline
2. Run a few queries manually
3. Get excited because it works
4. Ship it
5. Users find the 15% of queries where it fails badly
6. Trust drops to zero
7. Project gets shelved or enters an endless "improvement" phase with no clear metrics

The gap between "works on my examples" and "works reliably" is enormous. And you can't close that gap without rigorous evaluation.

### What Evaluation Actually Looks Like

We built an evaluation harness before we built most features. It has four components:

**A real query dataset.** Not queries we made up — queries from actual users, collected over time. Initially we seeded it with queries from stakeholders, but the most valuable queries are the ones real users ask that we didn't anticipate. We add 10-20 new queries to the dataset every week.

**Ground truth answers.** For each query, a human-written answer that serves as the gold standard. This is expensive to create — each answer takes 5-15 minutes of expert time. But it's the only way to measure quality objectively. We have about 300 ground truth pairs now. It took months to build this dataset. It's our most valuable asset.

**Automated scoring.** We use a combination of metrics: answer relevance (does the response address the query?), faithfulness (is the response supported by the retrieved documents?), and completeness (does the response cover all aspects of the ground truth?). We score these automatically using an LLM-as-judge approach, calibrated against human ratings.

**Regression detection.** Every change to the pipeline — new chunking strategy, new embedding model, prompt tweak, retrieval parameter change — triggers a full evaluation run against the dataset. If quality drops on any category of query, the change doesn't ship. This has caught subtle regressions multiple times, like a chunking change that improved performance on short queries but degraded long, multi-part questions.

### The Insight That Changed Our Approach

The most useful thing about our evaluation harness isn't the scores. It's the failure analysis.

When a query fails, we can trace back exactly why. Was the right document retrieved but the wrong chunk selected? Was the right chunk selected but insufficient context included? Was the model's generation unfaithful to the retrieved context? Each failure mode has a different fix.

We maintain a taxonomy of failure modes and track their frequency over time. This tells us where to invest engineering effort. Right now, our top failure mode is "correct chunk retrieved but missing cross-reference context" — which is why we invested heavily in the graph-based retrieval approach.

## The Freshness Problem

Documents change. This sounds obvious, but the implications for RAG systems are brutal.

People assume vector databases are like regular databases — you update the source, the index reflects it. They don't. Your vector database is a snapshot. If a policy document gets updated and you don't re-process it, your AI is confidently answering with outdated information. Users lose trust fast when they know something changed last week but the AI still gives the old answer.

### What A Real Ingestion Pipeline Looks Like

Ours watches for document changes through multiple channels: file system events, API polling, webhook integrations. When a change is detected:

1. **Diff detection:** We don't re-process the entire document. We identify which sections changed, which were added, which were deleted.

2. **Selective re-chunking:** Only affected sections get re-chunked. This matters for performance — re-processing 100k documents on every change would be prohibitively expensive.

3. **Re-embedding:** Changed chunks get new embeddings. Old embeddings for deleted or modified chunks get removed from the index.

4. **Graph update:** The document graph gets updated. If a new section references an existing one, that relationship gets added. If a section was deleted, dependent chunks get flagged for review.

5. **Staleness scoring:** Chunks get a freshness score based on when their source was last verified. If a chunk hasn't been verified in 30 days, it gets a lower retrieval priority. This prevents the system from confidently serving information from documents that might be outdated.

6. **Consistency check:** After ingestion, we run a subset of our evaluation queries that relate to the changed documents, verifying that answers are now correct and consistent.

This pipeline is boring infrastructure work. Nobody writes blog posts about it. It's not as exciting as prompt engineering or model evaluation. But it's the difference between a demo and a product that people trust.

## Token Optimization Is An Ongoing Battle

Context windows are large now, but they're not infinite. And even when they're large, stuffing them full of retrieved documents isn't free — it increases latency, increases cost, and paradoxically can decrease quality (the model gets lost in too much context).

We spent significant time on token optimization:

**Compression:** Before feeding retrieved chunks to the model, we summarize them if they're longer than a threshold. The summary retains key facts but uses fewer tokens.

**Relevance filtering:** Just because a chunk was retrieved doesn't mean it should be included. We apply a secondary relevance filter after retrieval, dropping chunks that scored below a dynamic threshold. Better to give the model four highly relevant chunks than twelve marginally relevant ones.

**Dynamic context allocation:** Different queries need different amounts of context. A factual question ("what's the retention policy for X?") needs one or two chunks. A synthesis question ("how does our approach to X compare to our approach to Y?") might need ten. We estimate query complexity and allocate context budget accordingly.

## What I'd Tell Someone Starting Today

Stop optimizing your embedding model first. Start with your chunking strategy — that's where 80% of quality lives.

Build evaluation before you build features. You can't improve what you can't measure, and intuition about AI quality is notoriously unreliable.

Plan for staleness from day one. If you don't have a freshness strategy, you'll discover you need one the hard way — through user complaints.

Accept that RAG is not an AI problem. It's a data engineering problem with an AI component. The teams that treat it this way ship reliable systems. The teams that focus on prompts and models ship impressive demos that don't survive contact with real users.

The LLM is the easy part. It's everything else that takes the time.
