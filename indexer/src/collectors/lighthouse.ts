import { config } from "../config.js";
import { fetch } from "undici";

// ── Real API response shapes (verified against live Lighthouse API) ───────────

export interface LighthouseStats {
  total_cc: string;
  total_reward: string;
  cc_price: string;
  total_validator: number;
  total_sv: number;
  total_transaction: number;
  total_parties: number;
  history_tx_14d?: Array<{ day: string; tx_count: number }>;
  durations?: Record<string, number>;
  [key: string]: unknown;
}

export interface LighthouseValidator {
  id: string;
  sponsor?: string;
  dso?: string;
  last_active_at?: string | null;
  first_round?: number;
  last_round?: number;
  miss_round?: number;
  version?: string;
  contact?: string;
  metadata_last_update?: string | null;
  created_at?: string;
  [key: string]: unknown;
}

export interface LighthouseValidatorDetail {
  validator: LighthouseValidator;
  balance?: { currency: string; total_cc: number };
  traffic_status?: unknown;
  [key: string]: unknown;
}

export interface LighthouseValidatorsResponse {
  count: number;
  validators: LighthouseValidator[];
}

export interface LighthouseReward {
  id: number;
  round: number;
  app_reward: string;
  validator_reward: string;
  sv_reward: string;
  created_at: string;
  [key: string]: unknown;
}

export interface LighthouseRewardsResponse {
  pagination: LighthousePagination;
  rewards: LighthouseReward[];
}

export interface LighthouseTransaction {
  id: number;
  update_id: string;
  migration_id?: number;
  record_time: string;
  effective_at?: string;
  workflow_id?: string | null;
  round?: number | null;
  [key: string]: unknown;
}

export interface LighthouseTransactionsResponse {
  pagination: LighthousePagination;
  transactions: LighthouseTransaction[];
}

export interface LighthouseTransfer {
  id: number;
  created_at: string;
  round?: number;
  amount: number;
  sender_address: string;
  receiver_address: string;
  event_id?: string;
  [key: string]: unknown;
}

export interface LighthouseTransfersResponse {
  pagination: LighthousePagination;
  transfers: LighthouseTransfer[];
}

export interface LighthouseRound {
  round: number;
  open_at: string;
  close_at?: string;
  total_tx: number;
  total_reward: number;
  issuance_per_sv_reward_coupon?: number;
  issuance_per_validator_reward_coupon?: number;
  [key: string]: unknown;
}

export interface LighthouseRoundsResponse {
  pagination: LighthousePagination;
  rounds: LighthouseRound[];
}

export interface LighthouseGovernanceVote {
  id: string;
  template_id?: string;
  [key: string]: unknown;
}

export interface LighthouseGovernanceResponse {
  count: number;
  total_sv: number;
  vote_requests: LighthouseGovernanceVote[];
}

export interface LighthouseContract {
  contract_id: string;
  template_id?: string;
  payload?: unknown;
  [key: string]: unknown;
}

export interface LighthouseContractsResponse {
  pagination?: LighthousePagination;
  contracts?: LighthouseContract[];
  [key: string]: unknown;
}

export interface LighthouseCnsRecord {
  domain_name: string;
  url?: string;
  party_address?: string;
  expires_at?: string;
  [key: string]: unknown;
}

export interface LighthouseCnsResponse {
  cns: LighthouseCnsRecord[];
  pagination?: LighthousePagination;
}

export interface LighthouseFeaturedApp {
  payload?: { provider?: string; [key: string]: unknown };
  created_at?: string;
  contract_id?: string;
  [key: string]: unknown;
}

export interface LighthouseFeaturedAppsResponse {
  apps: LighthouseFeaturedApp[];
}

export interface LighthousePreapproval {
  id: number;
  expired_at?: string;
  created_at?: string;
  provider?: string;
  receiver?: string;
  [key: string]: unknown;
}

export interface LighthousePreapprovalsResponse {
  pagination: LighthousePagination;
  preapprovals: LighthousePreapproval[];
}

export interface LighthouseSearchResponse {
  validators?: LighthouseValidator[];
  [key: string]: unknown;
}

export interface LighthousePagination {
  has_next?: boolean;
  has_previous?: boolean;
  next_cursor?: string | number;
  previous_cursor?: string | number;
  next_cursor_id?: number;
  previous_cursor_id?: number;
}

export interface PaginationParams {
  page_size?: string | number;
  page_token?: string;
  cursor?: string;
}

type RequestResult<T> = { ok: true; data: T } | { ok: false; status: number; error: string };

class LighthouseCollector {
  private readonly baseUrl: string;
  private readonly timeoutMs: number;

  constructor() {
    this.baseUrl = config.lighthouse.baseUrl;
    this.timeoutMs = config.lighthouse.timeoutMs;
  }

  private async get<T>(path: string, params?: Record<string, string>): Promise<RequestResult<T>> {
    const url = new URL(path, this.baseUrl);
    if (params) {
      for (const [k, v] of Object.entries(params)) {
        if (v !== undefined && v !== "") url.searchParams.set(k, v);
      }
    }

    try {
      const res = await fetch(url.toString(), {
        signal: AbortSignal.timeout(this.timeoutMs),
        headers: { Accept: "application/json" },
      });

      if (!res.ok) {
        const text = await res.text().catch(() => "");
        return { ok: false, status: res.status, error: text.slice(0, 200) };
      }

      const data = (await res.json()) as T;
      return { ok: true, data };
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      return { ok: false, status: 0, error: msg };
    }
  }

  // ── Stats ────────────────────────────────────────────────────────────────
  // cc_price is embedded in stats response — no separate prices endpoint exists

  async getStats(): Promise<RequestResult<LighthouseStats>> {
    return this.get<LighthouseStats>("/api/stats");
  }

  // ── Validators ───────────────────────────────────────────────────────────

  async getValidators(
    params?: PaginationParams,
  ): Promise<RequestResult<LighthouseValidatorsResponse>> {
    return this.get<LighthouseValidatorsResponse>("/api/validators", {
      ...(params?.page_size ? { page_size: String(params.page_size) } : {}),
    });
  }

  async getValidator(id: string): Promise<RequestResult<LighthouseValidatorDetail>> {
    return this.get<LighthouseValidatorDetail>(`/api/validators/${encodeURIComponent(id)}`);
  }

  // ── Parties ──────────────────────────────────────────────────────────────

  async getPartyRewards(
    partyId: string,
    params?: PaginationParams,
  ): Promise<RequestResult<LighthouseRewardsResponse>> {
    return this.get<LighthouseRewardsResponse>(
      `/api/parties/${encodeURIComponent(partyId)}/rewards`,
      { ...(params?.page_size ? { page_size: String(params.page_size) } : {}) },
    );
  }

  async getPartyBurns(partyId: string, params?: PaginationParams): Promise<RequestResult<unknown>> {
    return this.get<unknown>(`/api/parties/${encodeURIComponent(partyId)}/burns`, {
      ...(params?.page_size ? { page_size: String(params.page_size) } : {}),
    });
  }

  async getPartyPnl(partyId: string): Promise<RequestResult<unknown>> {
    return this.get<unknown>(`/api/parties/${encodeURIComponent(partyId)}/pnl`);
  }

  async getPartyTransfers(
    partyId: string,
    params?: PaginationParams,
  ): Promise<RequestResult<unknown>> {
    return this.get<unknown>(`/api/parties/${encodeURIComponent(partyId)}/transfers`, {
      ...(params?.page_size ? { page_size: String(params.page_size) } : {}),
    });
  }

  async getPartyTransactions(
    partyId: string,
    params?: PaginationParams,
  ): Promise<RequestResult<unknown>> {
    return this.get<unknown>(`/api/parties/${encodeURIComponent(partyId)}/transactions`, {
      ...(params?.page_size ? { page_size: String(params.page_size) } : {}),
    });
  }

  async getPartyBurnStats(partyId: string): Promise<RequestResult<unknown>> {
    return this.get<unknown>(`/api/parties/${encodeURIComponent(partyId)}/burn-stats`);
  }

  async getPartyRewardStats(partyId: string): Promise<RequestResult<unknown>> {
    return this.get<unknown>(`/api/parties/${encodeURIComponent(partyId)}/reward-stats`);
  }

  async getPartyBalance(partyId: string): Promise<RequestResult<unknown>> {
    return this.get<unknown>(`/api/parties/${encodeURIComponent(partyId)}/balance`);
  }

  // ── Transactions ─────────────────────────────────────────────────────────

  async getTransactions(
    params?: PaginationParams,
  ): Promise<RequestResult<LighthouseTransactionsResponse>> {
    return this.get<LighthouseTransactionsResponse>("/api/transactions", {
      ...(params?.page_size ? { page_size: String(params.page_size) } : {}),
    });
  }

  async getTransaction(updateId: string): Promise<RequestResult<LighthouseTransaction>> {
    return this.get<LighthouseTransaction>(`/api/transactions/${encodeURIComponent(updateId)}`);
  }

  // ── Transfers ────────────────────────────────────────────────────────────

  async getTransfers(
    params?: PaginationParams,
  ): Promise<RequestResult<LighthouseTransfersResponse>> {
    return this.get<LighthouseTransfersResponse>("/api/transfers", {
      ...(params?.page_size ? { page_size: String(params.page_size) } : {}),
    });
  }

  // Note: GET /api/transfers/:id → HTTP 500 (known Lighthouse bug) — not implemented

  // ── Contracts ────────────────────────────────────────────────────────────

  async getContracts(
    params?: PaginationParams,
  ): Promise<RequestResult<LighthouseContractsResponse>> {
    return this.get<LighthouseContractsResponse>("/api/contracts", {
      ...(params?.page_size ? { page_size: String(params.page_size) } : {}),
    });
  }

  async getContract(contractId: string): Promise<RequestResult<LighthouseContract>> {
    return this.get<LighthouseContract>(`/api/contracts/${encodeURIComponent(contractId)}`);
  }

  // ── Rounds ───────────────────────────────────────────────────────────────

  async getRounds(params?: PaginationParams): Promise<RequestResult<LighthouseRoundsResponse>> {
    return this.get<LighthouseRoundsResponse>("/api/rounds", {
      ...(params?.page_size ? { page_size: String(params.page_size) } : {}),
    });
  }

  async getRound(roundNumber: number): Promise<RequestResult<LighthouseRound>> {
    return this.get<LighthouseRound>(`/api/rounds/${roundNumber}`);
  }

  // ── Governance ───────────────────────────────────────────────────────────

  async getGovernanceVotes(
    params?: PaginationParams,
  ): Promise<RequestResult<LighthouseGovernanceResponse>> {
    return this.get<LighthouseGovernanceResponse>("/api/governance", {
      ...(params?.page_size ? { page_size: String(params.page_size) } : {}),
    });
  }

  async getGovernanceStats(): Promise<RequestResult<unknown>> {
    return this.get<unknown>("/api/governance/stats");
  }

  async getGovernanceVote(id: string): Promise<RequestResult<LighthouseGovernanceVote>> {
    return this.get<LighthouseGovernanceVote>(`/api/governance/${encodeURIComponent(id)}`);
  }

  // ── CNS ──────────────────────────────────────────────────────────────────

  async getCnsRecords(params?: PaginationParams): Promise<RequestResult<LighthouseCnsResponse>> {
    return this.get<LighthouseCnsResponse>("/api/cns", {
      ...(params?.page_size ? { page_size: String(params.page_size) } : {}),
    });
  }

  async getCnsRecord(domain: string): Promise<RequestResult<LighthouseCnsRecord>> {
    return this.get<LighthouseCnsRecord>(`/api/cns/${encodeURIComponent(domain)}`);
  }

  // ── Featured Apps ────────────────────────────────────────────────────────

  async getFeaturedApps(): Promise<RequestResult<LighthouseFeaturedAppsResponse>> {
    return this.get<LighthouseFeaturedAppsResponse>("/api/featured-apps");
  }

  // ── Preapprovals ─────────────────────────────────────────────────────────

  async getPreapprovals(
    params?: PaginationParams,
  ): Promise<RequestResult<LighthousePreapprovalsResponse>> {
    return this.get<LighthousePreapprovalsResponse>("/api/preapprovals", {
      ...(params?.page_size ? { page_size: String(params.page_size) } : {}),
    });
  }

  // ── Search ───────────────────────────────────────────────────────────────

  async search(query: string): Promise<RequestResult<LighthouseSearchResponse>> {
    return this.get<LighthouseSearchResponse>("/api/search", { q: query });
  }
}

export const lighthouse = new LighthouseCollector();
