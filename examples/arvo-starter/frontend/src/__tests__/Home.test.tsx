import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { HomePageProps } from "../arvo.gen";
import Home from "../pages/Home";
import { loadMoFixture } from "./fixtures";

const homeAfterPayFixture = loadMoFixture<HomePageProps>("Home", "home_after_pay");
const homeBaselineFixture = loadMoFixture<HomePageProps>("Home", "home_baseline");
const homeValidationFixture = loadMoFixture<HomePageProps>("Home", "home_validation_error");

const { postMock, setDataMock, resetMock, routerPostMock, routerReloadMock } = vi.hoisted(() => ({
  postMock: vi.fn(),
  setDataMock: vi.fn(),
  resetMock: vi.fn(),
  routerPostMock: vi.fn(),
  routerReloadMock: vi.fn(),
}));

vi.mock("@inertiajs/react", () => ({
  router: {
    post: routerPostMock,
    reload: routerReloadMock,
  },
  useForm: (initial: { name: string; category: string; amount_cents: string }) => ({
    data: initial,
    setData: setDataMock,
    post: postMock,
    reset: resetMock,
  }),
}));

describe("Home component with real Mo Inertia fixtures", () => {
  beforeEach(() => {
    postMock.mockReset();
    setDataMock.mockReset();
    resetMock.mockReset();
    routerPostMock.mockReset();
    routerReloadMock.mockReset();
    document.cookie = "XSRF-TOKEN=csrf_test%2B1; Path=/";
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("renders baseline fixture, submits Add Bill, and marks a bill paid via CSRF fetch", async () => {
    const user = userEvent.setup();
    const fetchSpy = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(new Response("{}", { status: 200 }));

    const props = homeBaselineFixture.props as unknown as HomePageProps;
    render(<Home {...props} />);

    expect(screen.getByRole("heading", { name: "Ada & Household <Team>" })).toBeInTheDocument();
    expect(screen.getByText("Due this paycheck: $145.00")).toBeInTheDocument();
    expect(screen.getByText("Electric & Gas <Utility>")).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: /Recent Audit Trail/ })).toBeInTheDocument();

    // Form inputs & submission
    await user.type(screen.getByLabelText("Bill name"), "W");
    expect(setDataMock).toHaveBeenCalledWith("name", "W");
    await user.selectOptions(screen.getByLabelText("Category"), "housing");
    expect(setDataMock).toHaveBeenCalledWith("category", "housing");
    await user.type(screen.getByLabelText("Amount in cents"), "9");
    expect(setDataMock).toHaveBeenCalledWith("amount_cents", "9");

    await user.click(screen.getByRole("button", { name: "Save Bill" }));
    expect(postMock).toHaveBeenCalledTimes(1);
    expect(postMock.mock.calls[0][0]).toBe("/bills");
    postMock.mock.calls[0][1].onSuccess();
    expect(resetMock).toHaveBeenCalledTimes(1);

    // Mark paid button posts JSON with expected_version and X-XSRF-TOKEN then reloads
    const payBtn = screen.getByRole("button", {
      name: "Mark paid Electric & Gas <Utility>",
    });
    await user.click(payBtn);
    expect(fetchSpy).toHaveBeenCalledWith(
      "/bills/1/pay",
      expect.objectContaining({
        method: "POST",
        credentials: "same-origin",
        headers: expect.objectContaining({
          "Content-Type": "application/json",
          "X-XSRF-TOKEN": "csrf_test+1",
        }),
        body: JSON.stringify({ expected_version: 1, reason: null }),
      }),
    );
    expect(routerReloadMock).toHaveBeenCalledTimes(1);

    // Sign out button
    await user.click(screen.getByRole("button", { name: "Sign out" }));
    expect(routerPostMock).toHaveBeenCalledWith("/logout");
  });

  it("shows accessible 409 conflict and HTTP error alerts when markPaid fails", async () => {
    const user = userEvent.setup();
    const props = homeBaselineFixture.props as unknown as HomePageProps;

    vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(new Response("{}", { status: 409 }));
    render(<Home {...props} />);
    await user.click(screen.getByRole("button", { name: "Mark paid Electric & Gas <Utility>" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("updated by someone else");
    expect(routerReloadMock).not.toHaveBeenCalled();

    vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(new Response("{}", { status: 500 }));
    await user.click(screen.getByRole("button", { name: "Mark paid Electric & Gas <Utility>" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("HTTP 500");

    vi.spyOn(globalThis, "fetch").mockRejectedValueOnce(new TypeError("Failed to fetch"));
    await user.click(screen.getByRole("button", { name: "Mark paid Electric & Gas <Utility>" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("network error");
    expect(screen.getByRole("button", { name: "Mark paid Electric & Gas <Utility>" })).toBeEnabled();
    expect(routerReloadMock).not.toHaveBeenCalled();
  });

  it("hides Mark paid on in_flight fixture and renders real validation errors", () => {
    const afterPayProps = homeAfterPayFixture.props as unknown as HomePageProps;
    const { unmount } = render(<Home {...afterPayProps} />);
    expect(screen.queryByRole("button", { name: /Mark paid/ })).not.toBeInTheDocument();
    expect(screen.getByText("(in_flight)")).toBeInTheDocument();
    unmount();

    const errProps = homeValidationFixture.props as unknown as HomePageProps;
    render(
      <Home
        {...errProps}
        auth={null}
        flash={{ notice: "Saved", alert: "Warning" }}
        errors={{ ...errProps.errors, category: "invalid category" }}
      />,
    );
    expect(screen.getByRole("heading", { name: "Household" })).toBeInTheDocument();
    expect(screen.getByRole("status")).toHaveTextContent("Saved");
    const alerts = screen.getAllByRole("alert");
    expect(alerts.some((el) => el.textContent?.includes("Warning"))).toBe(true);
    expect(alerts.some((el) => el.textContent?.includes("can't be blank"))).toBe(true);
    expect(alerts.some((el) => el.textContent?.includes("invalid category"))).toBe(true);
    expect(alerts.some((el) => el.textContent?.includes("greater than 0"))).toBe(true);
    expect(screen.getByLabelText("Bill name")).toHaveAttribute("aria-invalid", "true");
    expect(screen.getByLabelText("Bill name")).toHaveAttribute("aria-describedby", "bill-name-error");
    expect(screen.getByLabelText("Category")).toHaveAttribute("aria-invalid", "true");
    expect(screen.getByLabelText("Amount in cents")).toHaveAttribute("aria-invalid", "true");
    expect(screen.getByLabelText("Amount in cents")).toHaveAttribute(
      "aria-describedby",
      "bill-amount-error",
    );
  });
});
