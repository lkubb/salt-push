ok-pillar-check:
  test.succeed_with_changes:
    - name: "pillar says {{ salt['pillar.get']('common:greeting', 'MISSING') }}"
