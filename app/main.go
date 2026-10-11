package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	httpRequestsTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "Total number of HTTP requests processed by status code and path.",
		},
		[]string{"method", "path", "code"},
	)

	httpRequestDuration = prometheus.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "Histogram of HTTP request latencies in seconds.",
			Buckets: []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5},
		},
		[]string{"method", "path"},
	)

	inFlightRequests = prometheus.NewGauge(
		prometheus.GaugeOpts{
			Name: "app_in_flight_requests",
			Help: "Current number of in-flight requests being processed.",
		},
	)
)

func init() {
	prometheus.MustRegister(httpRequestsTotal)
	prometheus.MustRegister(httpRequestDuration)
	prometheus.MustRegister(inFlightRequests)
}

type statusWriter struct {
	http.ResponseWriter
	statusCode int
}

func (w *statusWriter) WriteHeader(code int) {
	w.statusCode = code
	w.ResponseWriter.WriteHeader(code)
}

// routeLabel returns the matched mux pattern to keep label cardinality bounded.
func routeLabel(r *http.Request) string {
	if r.Pattern != "" {
		return r.Pattern
	}
	return "unmatched"
}

func metricsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		inFlightRequests.Inc()
		defer inFlightRequests.Dec()

		start := time.Now()
		sw := &statusWriter{ResponseWriter: w, statusCode: http.StatusOK}

		next.ServeHTTP(sw, r)

		path := routeLabel(r)
		duration := time.Since(start).Seconds()
		httpRequestDuration.WithLabelValues(r.Method, path).Observe(duration)
		httpRequestsTotal.WithLabelValues(r.Method, path, strconv.Itoa(sw.statusCode)).Inc()
	})
}

func writeJSON(w http.ResponseWriter, body string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(body))
}

func main() {
	mux := http.NewServeMux()

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, `{"status":"healthy"}`)
	})

	mux.HandleFunc("/readyz", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, `{"status":"ready"}`)
	})

	mux.HandleFunc("/api/v1/workload", func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(10 * time.Millisecond) // Simulate processing
		writeJSON(w, `{"message":"execution verified"}`)
	})

	mux.Handle("/metrics", promhttp.Handler())

	server := &http.Server{
		Addr:              ":8080",
		Handler:           metricsMiddleware(mux),
		ReadHeaderTimeout: 3 * time.Second,
		ReadTimeout:       5 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	go func() {
		log.Printf("Starting HTTP API on :8080")
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("Server failed: %v", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	<-stop

	log.Printf("Shutting down server gracefully...")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := server.Shutdown(ctx); err != nil {
		log.Fatalf("Server forced to shutdown: %v", err)
	}
	log.Printf("Server exited cleanly.")
}
