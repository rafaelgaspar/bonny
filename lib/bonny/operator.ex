defmodule Bonny.Operator do
  @moduledoc ~S"""
  Defines a Bonny operator.

  The operator defines custom resources, watch queries and their
  controllers and serves as the entry point to the watching and handling of
  processes.

  Overall, an operator has the following responsibilities:

  * to provide a wrapper for starting and stopping the
    operator as part of a supervision tree

  * To define the resources to be watched together with the
    controllers which handle action events on those resources.

  * to define an initial pluggable pipeline for all action events
    to pass through

  * To define any custom resources ending up in the manifest
    generated by `mix bonny.gen.manifest`

  ## Operators

  An operator is defined with the help of `Bonyy.Operator`. The step
  `:delegate_to_controller` has do be part of the pipeline. It is the step that
  calls the handling controller for a given action event:

      defmodule MyOperatorApp.Operator do
        use Bonny.Operator, default_watching_namespace: "default"

        # step ...
        step :delegate_to_controller
        # step ...

        def controllers(watching_namespace, _opts) do
          [
            %{
              query: K8s.Client.watch("my-controller.io", "MyCustomResource", namespace: nil)
              controller: MyOperator.Controller.MyCustomResourceController
            }
          ]
        end


      end


  """

  alias Bonny.Axn

  @type controller_spec :: %{
          optional(:controller) => module() | {module(), keyword()},
          query: K8s.Operation.t()
        }

  @callback controllers(binary(), Keyword.t()) :: list(controller_spec())
  @callback crds() :: list(Bonny.API.CRD.t())

  @spec __using__(any) ::
          {:__block__, [],
           [{:@, [...], [...]} | {:__block__, [...], [...]} | {:use, [...], [...]}, ...]}
  defmacro __using__(opts) do
    quote do
      use Pluggable.StepBuilder

      @behaviour Bonny.Operator

      unquote(server(opts))

      @before_compile Bonny.Operator
    end
  end

  def __before_compile__(env) do
    if !Enum.any?(
         Module.get_attribute(env.module, :steps),
         &(elem(&1, 0) == :delegate_to_controller)
       ) do
      raise CompileError,
        description:
          "Operators must define a step :delegate_to_controller. Add it to #{env.module}."
    end
  end

  defp server(opts) do
    quote location: :keep do
      @default_watch_namespace unquote(opts)[:default_watch_namespace] ||
                                 raise(CompileError,
                                   description:
                                     "operator expects :default_watch_namespace to be given"
                                 )

      @doc """
      Returns the child specification to start the operator
      under a supervision tree.
      """
      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]},
          type: :supervisor
        }
      end

      @doc """
      Starts the operator supervision tree.

      ## Init Arguments

        * `:conn` - Required - The `%K8s.Conn{}` struct defining the connection to Kubernetes.
        * `:watch_namespace` - The namespache to be watched. Defaults to "default"

      All other options are passed to `controllers/2` and merged into the
      operator configuration.
      """
      def start_link(init_args \\ []) do
        {watch_namespace, init_args} =
          Keyword.pop(init_args, :watch_namespace, @default_watch_namespace)

        controllers(watch_namespace, init_args)
        |> Enum.map(&Bonny.Operator.prepare_controller_for_supervisor/1)
        |> Bonny.Operator.Supervisor.start_link(__MODULE__, init_args)
      end

      @doc """
      Runs the controller pipeline for the current action event.
      """
      def delegate_to_controller(%Bonny.Axn{controller: nil} = axn, _step_opts), do: axn

      def delegate_to_controller(%Bonny.Axn{controller: {controller, opts}} = axn, _step_opts) do
        controller.call(axn, controller.init(opts))
      end
    end
  end

  @doc false
  @spec run({atom(), Bonny.Resource.t()}, {module(), keyword()}, module(), K8s.Conn.t()) :: :ok
  def run({action, resource}, controller, operator, conn) do
    Axn.new!(
      conn: conn,
      action: action,
      resource: resource,
      controller: controller,
      operator: operator
    )
    |> operator.call([])
    |> Bonny.Axn.emit_events()
    |> Bonny.Axn.run_after_processed()

    :ok
  end

  @doc false
  @spec prepare_controller_for_supervisor(controller_spec()) :: [{module(), keyword()}]
  def prepare_controller_for_supervisor(controller) do
    Map.update(controller, :controller, nil, fn
      {controller, init_opts} -> {controller, init_opts}
      controller -> {controller, []}
    end)
    |> Map.to_list()
  end
end
