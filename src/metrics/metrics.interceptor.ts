import {
  CallHandler,
  ExecutionContext,
  Injectable,
  NestInterceptor,
} from '@nestjs/common';
import { Observable, finalize } from 'rxjs';
import { MetricsService } from './metrics.service';

interface HttpRequest {
  path?: string;
  route?: { path?: string };
}

@Injectable()
export class MetricsInterceptor implements NestInterceptor {
  constructor(private readonly metrics: MetricsService) {}

  intercept(context: ExecutionContext, next: CallHandler): Observable<unknown> {
    const request = context.switchToHttp().getRequest<HttpRequest>();
    const route = request.route?.path ?? request.path ?? 'unknown';
    const finish = this.metrics.startRequest(route);

    return next.handle().pipe(finalize(finish));
  }
}
