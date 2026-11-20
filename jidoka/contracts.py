"""Payloads shared by the collector, review engine and web worker."""

from typing import Literal, NotRequired, TypedDict


class SourceFile(TypedDict):
    path: str
    patch: str
    before: str
    after: str


class Snapshot(TypedDict):
    url: str
    repo: str
    number: int
    base: str
    head: str
    intent: list[str]
    files: list[SourceFile]
    limits: list[str]


class Signal(TypedDict):
    rule: str
    path: str
    line: int
    message: str


class Scan(TypedDict):
    signals: list[Signal]
    limits: list[str]
    version: str
    covered: list[str]


class Focus(TypedDict):
    path: str
    line: int
    checked: str
    outcome: str
    action: str


class Finding(TypedDict):
    path: str
    line: int
    title: str
    impact: str
    evidence: str
    attribution: Literal["introduced", "preexisting", "unknown"]


class Report(TypedDict):
    focus: list[Focus]
    findings: list[Finding]
    limits: list[str]


class PublishedReport(Report):
    scan: NotRequired[Scan]
    repo: str
    base: str
    head: str
