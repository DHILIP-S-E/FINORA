# Demo video script (target 3:15, hard limit 4:00)

Live API: https://finora-api-510528501361.asia-south1.run.app/docs  (Swagger UI)
Record the screen with voice-over (OBS, or Win+G). Keep the browser at 125% zoom.

**0:00-0:25  Problem (slide 3 of the deck)**
"Banking apps show today's balance. They don't show that a late client payment, a loan EMI and a card bill can collide three weeks from now. CASCADE finds those compound risks."

**0:25-0:50  Architecture (deck slide 8)**
"Flutter client, Firebase Auth, a FastAPI service on Cloud Run, Firestore for data, and Gemini 2.5 Flash on Vertex AI. Rule: the AI proposes and explains; a deterministic engine computes every number."

**0:50-1:30  Live: auth + data (Swagger UI)**
1. Open /docs. Say: "This is the deployed Cloud Run service."
2. Get a Firebase anonymous token (paste a prepared token into Authorize, or show the app sign-in).
3. POST /api/v1/demo/seed -> "synthetic freelancer Asha, written to Firestore".
4. GET /api/v1/cashflow -> point at opening 42,000, lowest 5,800 on 21 Nov.

**1:30-2:30  Live: Gemini discovery**
1. POST /api/v1/scenarios/discover -> show `labels`: provider gemini, live_ai true, numbers simulated_by_engine.
2. Open one candidate: disruptions, assumptions, uncertainties, evaluation (shortfall dates, max deficit).
3. Say: "Gemini only chose the events. The shortfall figures come from the engine."

**2:30-3:05  Live: assistant**
POST /api/v1/assistant/query {"message":"What if Client A pays 10 days late?"} -> show facts, assumptions, citations, needs_confirmation.

**3:05-3:30  Safety + close (deck slide 14)**
"Untrusted-data prompts, schema-validated output, no probabilities, unknowns listed, rate limits, per-user Firestore. 51 backend tests pass. Code is on GitHub."
