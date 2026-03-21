package docker

import (
	"context"
	"fmt"
	"io"
	"path/filepath"

	"github.com/docker/docker/api/types/container"
	"github.com/docker/docker/api/types/mount"
	"github.com/docker/docker/api/types/network"
	"github.com/docker/docker/client"
)

type Manager struct {
	cli         *client.Client
	image       string
	networkName string
	dataDir     string
	proxyURL    string
	extraEnv    []string
}

type CreateOpts struct {
	ID            string
	TelegramToken string
	ProxyKey      string
	Model         string
}

func NewManager(image, networkName, dataDir, proxyURL string, extraEnv []string) (*Manager, error) {
	cli, err := client.NewClientWithOpts(client.FromEnv, client.WithAPIVersionNegotiation())
	if err != nil {
		return nil, err
	}
	return &Manager{cli: cli, image: image, networkName: networkName, dataDir: dataDir, proxyURL: proxyURL, extraEnv: extraEnv}, nil
}

func (m *Manager) CreateAndStart(ctx context.Context, opts CreateOpts) (string, error) {
	instanceDir, err := filepath.Abs(filepath.Join(m.dataDir, "instances", opts.ID))
	if err != nil {
		return "", fmt.Errorf("resolve instance dir: %w", err)
	}
	containerName := "druzhok-" + opts.ID

	resp, err := m.cli.ContainerCreate(ctx,
		&container.Config{
			Image: m.image,
			Env: append([]string{
				"DRUZHOK_TELEGRAM_TOKEN=" + opts.TelegramToken,
				"DRUZHOK_PROXY_URL=" + m.proxyURL,
				"DRUZHOK_PROXY_KEY=" + opts.ProxyKey,
				"DRUZHOK_WORKSPACE_DIR=/data/workspace",
				"DRUZHOK_CONFIG_PATH=/data/druzhok.json",
			}, m.extraEnv...),
		},
		&container.HostConfig{
			Mounts: []mount.Mount{
				{
					Type:   mount.TypeBind,
					Source: instanceDir,
					Target: "/data",
				},
			},
			RestartPolicy: container.RestartPolicy{Name: "unless-stopped"},
		},
		&network.NetworkingConfig{
			EndpointsConfig: map[string]*network.EndpointSettings{
				m.networkName: {},
			},
		},
		nil,
		containerName,
	)
	if err != nil {
		return "", fmt.Errorf("create container: %w", err)
	}

	if err := m.cli.ContainerStart(ctx, resp.ID, container.StartOptions{}); err != nil {
		return "", fmt.Errorf("start container: %w", err)
	}

	return resp.ID, nil
}

func (m *Manager) Stop(ctx context.Context, containerID string) error {
	return m.cli.ContainerStop(ctx, containerID, container.StopOptions{})
}

func (m *Manager) Remove(ctx context.Context, containerID string) error {
	return m.cli.ContainerRemove(ctx, containerID, container.RemoveOptions{Force: true})
}

func (m *Manager) IsRunning(ctx context.Context, containerID string) (bool, error) {
	inspect, err := m.cli.ContainerInspect(ctx, containerID)
	if err != nil {
		return false, err
	}
	return inspect.State.Running, nil
}

func (m *Manager) Logs(ctx context.Context, containerID string, tail int) (string, error) {
	reader, err := m.cli.ContainerLogs(ctx, containerID, container.LogsOptions{
		ShowStdout: true,
		ShowStderr: true,
		Tail:       fmt.Sprintf("%d", tail),
	})
	if err != nil {
		return "", err
	}
	defer reader.Close()

	data, err := io.ReadAll(reader)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

func (m *Manager) Close() error {
	return m.cli.Close()
}

func (m *Manager) EnsureNetwork(ctx context.Context) error {
	_, err := m.cli.NetworkInspect(ctx, m.networkName, network.InspectOptions{})
	if err == nil {
		return nil
	}
	_, err = m.cli.NetworkCreate(ctx, m.networkName, network.CreateOptions{
		Driver: "bridge",
	})
	return err
}
