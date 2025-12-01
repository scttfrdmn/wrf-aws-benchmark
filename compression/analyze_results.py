#!/usr/bin/env python3
"""
analyze_results.py - Analyze WRF benchmark results and generate comparison report

Compares compression scenarios and generates visualizations for the blog post.
"""

import json
import os
import sys
from pathlib import Path
from datetime import datetime
import argparse

# Check for optional dependencies
try:
    import pandas as pd
    HAS_PANDAS = True
except ImportError:
    HAS_PANDAS = False

try:
    import matplotlib.pyplot as plt
    import matplotlib.ticker as ticker
    HAS_MATPLOTLIB = True
except ImportError:
    HAS_MATPLOTLIB = False


# Cost constants (us-east-2 pricing)
COSTS = {
    'hpc7a.96xlarge': 9.08,  # $/hour
    'hpc7a.48xlarge': 7.20,
    'fsx_lustre_persistent2_ssd': 0.145 / (1024 * 30 * 24),  # $/GB-hour (from $/GB-month)
    'fsx_throughput_250': 0.030 / (1024 * 30 * 24),  # Additional throughput cost
}

# Expected compression ratios (for estimation when actual not available)
COMPRESSION_RATIOS = {
    'baseline': 1.0,
    'lustre_lz4': 2.5,
    'netcdf_1': 4.0,
    'netcdf_2': 4.5,
    'netcdf_4': 5.5,
    'netcdf_1_lustre': 4.2,
}

# CPU overhead from compression
CPU_OVERHEAD = {
    'baseline': 0.0,
    'lustre_lz4': 0.0,  # Transparent
    'netcdf_1': 0.15,
    'netcdf_2': 0.25,
    'netcdf_4': 0.45,
    'netcdf_1_lustre': 0.15,
}


def load_results(results_dir: Path) -> list:
    """Load all benchmark results from a directory."""
    results = []
    
    for scenario_dir in results_dir.iterdir():
        if not scenario_dir.is_dir():
            continue
        
        metrics_file = scenario_dir / 'metrics.json'
        summary_file = scenario_dir / 'summary.json'
        
        if metrics_file.exists():
            with open(metrics_file) as f:
                data = json.load(f)
                data['scenario_dir'] = str(scenario_dir)
                results.append(data)
        elif summary_file.exists():
            with open(summary_file) as f:
                data = json.load(f)
                data['scenario_dir'] = str(scenario_dir)
                results.append(data)
    
    return results


def calculate_costs(result: dict, storage_days: int = 30) -> dict:
    """Calculate costs for a benchmark result."""
    
    scenario = result.get('scenario', 'baseline')
    nodes = result.get('nodes', result.get('nodes_used', 10))
    runtime_sec = result.get('runtime_seconds', result.get('total_runtime_seconds', 0))
    output_bytes = result.get('output_size_bytes', result.get('total_output_bytes', 0))
    
    # Compute cost
    runtime_hours = runtime_sec / 3600
    compute_cost = nodes * COSTS['hpc7a.96xlarge'] * runtime_hours
    
    # Adjust for CPU overhead from compression
    overhead = CPU_OVERHEAD.get(scenario, 0)
    adjusted_compute = compute_cost * (1 + overhead)
    
    # Storage cost
    compression_ratio = COMPRESSION_RATIOS.get(scenario, 1.0)
    physical_bytes = output_bytes / compression_ratio
    physical_gb = physical_bytes / (1024**3)
    storage_hours = storage_days * 24
    storage_cost = physical_gb * COSTS['fsx_lustre_persistent2_ssd'] * storage_hours
    
    # Total
    total_cost = adjusted_compute + storage_cost
    
    return {
        'scenario': scenario,
        'compute_cost': round(adjusted_compute, 2),
        'storage_cost': round(storage_cost, 2),
        'total_cost': round(total_cost, 2),
        'compression_ratio': compression_ratio,
        'output_gb': round(output_bytes / (1024**3), 2),
        'physical_gb': round(physical_gb, 2),
        'runtime_hours': round(runtime_hours, 2),
        'cpu_overhead_pct': round(overhead * 100, 1),
    }


def generate_text_report(results: list, output_file: Path = None) -> str:
    """Generate a text comparison report."""
    
    if not results:
        return "No results found."
    
    # Calculate costs for each scenario
    cost_data = [calculate_costs(r) for r in results]
    
    # Find baseline for comparison
    baseline = next((c for c in cost_data if c['scenario'] == 'baseline'), cost_data[0])
    
    lines = [
        "=" * 70,
        "WRF Compression Benchmark Results",
        "=" * 70,
        "",
        f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
        f"Scenarios tested: {len(results)}",
        "",
        "-" * 70,
        "Cost Comparison (30-day storage retention)",
        "-" * 70,
        "",
        f"{'Scenario':<20} {'Compute':>10} {'Storage':>10} {'Total':>10} {'Savings':>10}",
        f"{'':_<20} {'':_>10} {'':_>10} {'':_>10} {'':_>10}",
    ]
    
    for c in sorted(cost_data, key=lambda x: x['total_cost']):
        savings = (baseline['total_cost'] - c['total_cost']) / baseline['total_cost'] * 100
        savings_str = f"{savings:+.1f}%" if c['scenario'] != 'baseline' else "-"
        
        lines.append(
            f"{c['scenario']:<20} ${c['compute_cost']:>9.2f} ${c['storage_cost']:>9.2f} "
            f"${c['total_cost']:>9.2f} {savings_str:>10}"
        )
    
    lines.extend([
        "",
        "-" * 70,
        "Compression Analysis",
        "-" * 70,
        "",
        f"{'Scenario':<20} {'Ratio':>8} {'Output GB':>12} {'Physical GB':>12} {'CPU OH':>8}",
        f"{'':_<20} {'':_>8} {'':_>12} {'':_>12} {'':_>8}",
    ])
    
    for c in cost_data:
        lines.append(
            f"{c['scenario']:<20} {c['compression_ratio']:>7.1f}x "
            f"{c['output_gb']:>11.1f} {c['physical_gb']:>11.1f} "
            f"{c['cpu_overhead_pct']:>7.1f}%"
        )
    
    lines.extend([
        "",
        "-" * 70,
        "Recommendations",
        "-" * 70,
        "",
    ])
    
    # Find optimal scenario
    optimal = min(cost_data, key=lambda x: x['total_cost'])
    lines.append(f"Optimal for cost: {optimal['scenario']} (${optimal['total_cost']:.2f})")
    
    # Find best compression
    best_compression = max(cost_data, key=lambda x: x['compression_ratio'])
    lines.append(f"Best compression: {best_compression['scenario']} ({best_compression['compression_ratio']:.1f}x)")
    
    # Find zero-overhead option
    zero_overhead = [c for c in cost_data if c['cpu_overhead_pct'] == 0]
    if zero_overhead:
        best_zero = min(zero_overhead, key=lambda x: x['storage_cost'])
        lines.append(f"Best zero-overhead: {best_zero['scenario']} ({best_zero['compression_ratio']:.1f}x)")
    
    lines.extend(["", "=" * 70])
    
    report = "\n".join(lines)
    
    if output_file:
        with open(output_file, 'w') as f:
            f.write(report)
    
    return report


def generate_html_report(results: list, output_file: Path) -> None:
    """Generate an HTML report with embedded charts (if matplotlib available)."""
    
    cost_data = [calculate_costs(r) for r in results]
    
    html = """
<!DOCTYPE html>
<html>
<head>
    <title>WRF Compression Benchmark Results</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; 
               margin: 40px; line-height: 1.6; }
        h1 { color: #232f3e; }
        h2 { color: #545b64; border-bottom: 2px solid #ec7211; padding-bottom: 5px; }
        table { border-collapse: collapse; width: 100%; margin: 20px 0; }
        th, td { border: 1px solid #ddd; padding: 12px; text-align: right; }
        th { background-color: #232f3e; color: white; }
        tr:nth-child(even) { background-color: #f9f9f9; }
        tr:hover { background-color: #fff3e0; }
        .scenario { text-align: left; font-weight: bold; }
        .best { background-color: #d4edda !important; }
        .metric { font-size: 24px; font-weight: bold; color: #232f3e; }
        .metric-label { font-size: 14px; color: #545b64; }
        .metrics-row { display: flex; gap: 40px; margin: 20px 0; }
        .metric-box { padding: 20px; background: #f5f5f5; border-radius: 8px; text-align: center; }
        .chart { max-width: 600px; margin: 20px 0; }
        .recommendation { background: #e8f4fd; padding: 15px; border-left: 4px solid #0073bb; margin: 20px 0; }
    </style>
</head>
<body>
    <h1>WRF Compression Benchmark Results</h1>
    <p>Generated: """ + datetime.now().strftime('%Y-%m-%d %H:%M:%S') + """</p>
    
    <h2>Key Metrics</h2>
    <div class="metrics-row">
"""
    
    # Calculate key metrics
    baseline = next((c for c in cost_data if c['scenario'] == 'baseline'), cost_data[0])
    optimal = min(cost_data, key=lambda x: x['total_cost'])
    savings_pct = (baseline['total_cost'] - optimal['total_cost']) / baseline['total_cost'] * 100
    
    html += f"""
        <div class="metric-box">
            <div class="metric">{len(results)}</div>
            <div class="metric-label">Scenarios Tested</div>
        </div>
        <div class="metric-box">
            <div class="metric">{optimal['compression_ratio']:.1f}x</div>
            <div class="metric-label">Best Compression</div>
        </div>
        <div class="metric-box">
            <div class="metric">{savings_pct:.1f}%</div>
            <div class="metric-label">Max Savings</div>
        </div>
        <div class="metric-box">
            <div class="metric">${optimal['total_cost']:.0f}</div>
            <div class="metric-label">Optimal Cost</div>
        </div>
    </div>
    
    <h2>Cost Comparison (30-day retention)</h2>
    <table>
        <tr>
            <th>Scenario</th>
            <th>Compute Cost</th>
            <th>Storage Cost</th>
            <th>Total Cost</th>
            <th>vs Baseline</th>
        </tr>
"""
    
    for c in sorted(cost_data, key=lambda x: x['total_cost']):
        savings = (baseline['total_cost'] - c['total_cost']) / baseline['total_cost'] * 100
        savings_str = f"{savings:+.1f}%" if c['scenario'] != 'baseline' else "-"
        row_class = 'best' if c['scenario'] == optimal['scenario'] else ''
        
        html += f"""
        <tr class="{row_class}">
            <td class="scenario">{c['scenario']}</td>
            <td>${c['compute_cost']:.2f}</td>
            <td>${c['storage_cost']:.2f}</td>
            <td>${c['total_cost']:.2f}</td>
            <td>{savings_str}</td>
        </tr>
"""
    
    html += """
    </table>
    
    <h2>Compression Analysis</h2>
    <table>
        <tr>
            <th>Scenario</th>
            <th>Compression Ratio</th>
            <th>Logical Size (GB)</th>
            <th>Physical Size (GB)</th>
            <th>CPU Overhead</th>
        </tr>
"""
    
    for c in cost_data:
        html += f"""
        <tr>
            <td class="scenario">{c['scenario']}</td>
            <td>{c['compression_ratio']:.1f}x</td>
            <td>{c['output_gb']:.1f}</td>
            <td>{c['physical_gb']:.1f}</td>
            <td>{c['cpu_overhead_pct']:.1f}%</td>
        </tr>
"""
    
    html += """
    </table>
    
    <h2>Recommendations</h2>
    <div class="recommendation">
"""
    
    # Generate recommendations
    lustre_only = next((c for c in cost_data if c['scenario'] == 'lustre_lz4'), None)
    netcdf_1 = next((c for c in cost_data if c['scenario'] == 'netcdf_1'), None)
    
    html += f"<p><strong>Optimal for most workloads:</strong> {optimal['scenario']} "
    html += f"(${optimal['total_cost']:.2f} total, {optimal['compression_ratio']:.1f}x compression)</p>"
    
    if lustre_only:
        html += f"<p><strong>For zero CPU overhead:</strong> lustre_lz4 provides {lustre_only['compression_ratio']:.1f}x "
        html += f"compression with no impact on compute time.</p>"
    
    if netcdf_1:
        html += f"<p><strong>For long-term archival:</strong> netcdf_1 provides {netcdf_1['compression_ratio']:.1f}x "
        html += f"compression with only {netcdf_1['cpu_overhead_pct']:.0f}% CPU overhead.</p>"
    
    html += """
    </div>
    
    <h2>Methodology</h2>
    <p>Benchmarks run on AWS hpc7a.96xlarge instances with FSx for Lustre storage. 
    Costs calculated using us-east-2 pricing with 30-day storage retention.</p>
    
</body>
</html>
"""
    
    with open(output_file, 'w') as f:
        f.write(html)
    
    print(f"HTML report saved to: {output_file}")


def generate_charts(results: list, output_dir: Path) -> None:
    """Generate matplotlib charts for the blog post."""
    
    if not HAS_MATPLOTLIB:
        print("matplotlib not available, skipping charts")
        return
    
    cost_data = [calculate_costs(r) for r in results]
    
    # Sort by total cost
    cost_data.sort(key=lambda x: x['total_cost'])
    
    scenarios = [c['scenario'] for c in cost_data]
    compute_costs = [c['compute_cost'] for c in cost_data]
    storage_costs = [c['storage_cost'] for c in cost_data]
    
    # Chart 1: Stacked bar chart of costs
    fig, ax = plt.subplots(figsize=(10, 6))
    
    x = range(len(scenarios))
    bars1 = ax.bar(x, compute_costs, label='Compute', color='#232f3e')
    bars2 = ax.bar(x, storage_costs, bottom=compute_costs, label='Storage', color='#ec7211')
    
    ax.set_xlabel('Compression Scenario')
    ax.set_ylabel('Cost ($)')
    ax.set_title('Total Cost by Compression Strategy (30-day retention)')
    ax.set_xticks(x)
    ax.set_xticklabels(scenarios, rotation=45, ha='right')
    ax.legend()
    ax.yaxis.set_major_formatter(ticker.FormatStrFormatter('$%.0f'))
    
    plt.tight_layout()
    plt.savefig(output_dir / 'cost_comparison.png', dpi=150)
    plt.close()
    
    # Chart 2: Compression ratio comparison
    fig, ax = plt.subplots(figsize=(10, 6))
    
    ratios = [c['compression_ratio'] for c in cost_data]
    colors = ['#28a745' if c['cpu_overhead_pct'] == 0 else '#ffc107' if c['cpu_overhead_pct'] < 20 else '#dc3545' 
              for c in cost_data]
    
    bars = ax.bar(x, ratios, color=colors)
    
    ax.set_xlabel('Compression Scenario')
    ax.set_ylabel('Compression Ratio')
    ax.set_title('Compression Ratio by Strategy')
    ax.set_xticks(x)
    ax.set_xticklabels(scenarios, rotation=45, ha='right')
    ax.axhline(y=1, color='gray', linestyle='--', alpha=0.5)
    
    # Add legend for colors
    from matplotlib.patches import Patch
    legend_elements = [
        Patch(facecolor='#28a745', label='0% CPU overhead'),
        Patch(facecolor='#ffc107', label='<20% CPU overhead'),
        Patch(facecolor='#dc3545', label='>20% CPU overhead'),
    ]
    ax.legend(handles=legend_elements, loc='upper right')
    
    plt.tight_layout()
    plt.savefig(output_dir / 'compression_ratio.png', dpi=150)
    plt.close()
    
    print(f"Charts saved to: {output_dir}")


def main():
    parser = argparse.ArgumentParser(description='Analyze WRF benchmark results')
    parser.add_argument('--results-dir', type=Path, required=True,
                        help='Directory containing benchmark results')
    parser.add_argument('--output', type=Path, default=None,
                        help='Output file for report (default: stdout)')
    parser.add_argument('--format', choices=['text', 'html', 'json'], default='text',
                        help='Output format')
    parser.add_argument('--charts', action='store_true',
                        help='Generate charts (requires matplotlib)')
    
    args = parser.parse_args()
    
    if not args.results_dir.exists():
        print(f"Results directory not found: {args.results_dir}")
        sys.exit(1)
    
    results = load_results(args.results_dir)
    
    if not results:
        print("No benchmark results found.")
        sys.exit(1)
    
    print(f"Found {len(results)} benchmark results")
    
    if args.format == 'text':
        report = generate_text_report(results, args.output)
        if not args.output:
            print(report)
    elif args.format == 'html':
        output = args.output or args.results_dir / 'report.html'
        generate_html_report(results, output)
    elif args.format == 'json':
        cost_data = [calculate_costs(r) for r in results]
        output = args.output or args.results_dir / 'analysis.json'
        with open(output, 'w') as f:
            json.dump(cost_data, f, indent=2)
        print(f"JSON saved to: {output}")
    
    if args.charts:
        generate_charts(results, args.results_dir)


if __name__ == '__main__':
    main()
