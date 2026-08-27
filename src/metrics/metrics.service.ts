import { Injectable } from '@nestjs/common';
import {
  collectDefaultMetrics,
  Counter,
  Histogram,
  Registry,
} from 'prom-client';

@Injectable()
export class MetricsService {
  private readonly registry = new Registry();
  private readonly requests = new Counter({
    name: 'kubescope_http_requests_total',
    help: 'Total number of HTTP requests handled by KubeScope',
    labelNames: ['route', 'environment'] as const,
    registers: [this.registry],
  });
  private readonly duration = new Histogram({
    name: 'kubescope_http_request_duration_seconds',
    help: 'Duration of HTTP requests handled by KubeScope',
    labelNames: ['route', 'environment'] as const,
    buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1],
    registers: [this.registry],
  });

  constructor() {
    collectDefaultMetrics({ register: this.registry, prefix: 'kubescope_' });
  }

  startRequest(route: string): () => void {
    const labels = {
      route,
      environment: process.env.APP_ENV ?? 'local',
    };
    const stopTimer = this.duration.startTimer(labels);

    return () => {
      this.requests.inc(labels);
      stopTimer();
    };
  }

  async render(): Promise<string> {
    return this.registry.metrics();
  }

  contentType(): string {
    return this.registry.contentType;
  }
}
